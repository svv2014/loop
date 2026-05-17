#!/usr/bin/env bash
# check-scanner-liveness.sh — watchdog for the Loop scanner liveness heartbeat.
#
# Runs every 5 minutes via launchd (macOS) or cron (Linux).
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat; if the file's mtime is older than
# LOOP_SCANNER_STALE_THRESHOLD seconds (default: 600 = 2× the 300s poll
# interval), the scanner is considered wedged and is killed so that launchd
# (KeepAlive=true) or the cron entry restarts it automatically.
#
# Exit codes: always 0 (launchd must not penalise the watchdog).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-600}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age_seconds <path>
# Prints seconds since the file's last modification. Returns 1 if the file
# does not exist (treat missing heartbeat as infinitely stale).
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo "999999"; return 0; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null) \
        || mtime=$(stat -c%Y "$path" 2>/dev/null) \
        || { echo "999999"; return 0; }
    now=$(date +%s)
    echo $(( now - mtime ))
}

main() {
    local age
    age=$(_file_age_seconds "$HEARTBEAT_FILE")

    log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

    if [ "$age" -lt "$STALE_THRESHOLD" ]; then
        log "scanner is live — nothing to do"
        return 0
    fi

    log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — restarting"

    # Read the scanner PID from the advisory lock file.
    local pid=""
    if [ -f "$SCANNER_LOCK" ]; then
        pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        # Force-kill if still alive after SIGTERM.
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    else
        log "no live scanner PID found in $SCANNER_LOCK — lock may already be stale"
        rm -f "$SCANNER_LOCK"
    fi

    # On macOS, kickstart the launchd agent so it restarts immediately rather
    # than waiting for the next ThrottleInterval window.
    if command -v launchctl >/dev/null 2>&1; then
        log "kickstarting com.user.loop-scanner via launchctl"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl start com.user.loop-scanner 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd KeepAlive will restart on next check"
    fi

    return 0
}

main "$@"
