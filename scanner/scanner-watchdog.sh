#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# Reads the heartbeat file written by scanner.sh on every tick.
# If the file is absent or its mtime is older than STALE_THRESHOLD_SECONDS,
# kills the scanner process (launchd KeepAlive then restarts it automatically
# on macOS; on Linux the cron next tick fires a fresh --once run).
#
# Usage:
#   scanner-watchdog.sh           # normal operation
#   scanner-watchdog.sh --dry-run # report only, no kill/restart
#
# Environment:
#   LOOP_SCANNER_INTERVAL          poll interval in seconds (default 300)
#   LOOP_WATCHDOG_STALE_MULTIPLIER multiplier applied to poll interval (default 2)
#   LOOP_SCANNER_LABEL             launchd label (default com.user.loop-scanner)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_MULTIPLIER="${LOOP_WATCHDOG_STALE_MULTIPLIER:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_MULTIPLIER ))
# Clamp to at least 600s to avoid false positives on slow ticks.
[ "$STALE_THRESHOLD" -lt 600 ] && STALE_THRESHOLD=600
SCANNER_LABEL="${LOOP_SCANNER_LABEL:-com.user.loop-scanner}"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _heartbeat_age — print seconds since heartbeat file was last modified.
# If the file does not exist, prints a very large number so the stale check
# always triggers (absence == scanner never ticked since last restart).
_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "9999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — return the PID recorded in the lock file, or empty if
# the lock file is absent or the recorded PID is no longer alive.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 0
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null && echo "$pid" || true
}

# _restart_scanner — kill the scanner (if alive) and signal launchd/cron
# to restart it. On macOS: launchctl kickstart -k. On Linux: the scanner
# uses --once mode via cron, so just killing the PID is sufficient (the
# next cron tick brings up a fresh run).
_restart_scanner() {
    local pid
    pid=$(_scanner_pid)

    if [ -n "$pid" ]; then
        log "killing wedged scanner PID $pid"
        $DRY_RUN || kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        # Force-kill if still alive after SIGTERM.
        $DRY_RUN || kill -0 "$pid" 2>/dev/null && \
            { $DRY_RUN || kill -KILL "$pid" 2>/dev/null || true; }
    else
        log "scanner PID not found (lock absent or already dead)"
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        local uid
        uid=$(id -u)
        log "kickstarting via launchctl gui/$uid/$SCANNER_LABEL"
        $DRY_RUN || launchctl kickstart -k "gui/$uid/$SCANNER_LABEL" 2>/dev/null || \
            log "WARN: launchctl kickstart failed — launchd will restart on next cycle"
    else
        log "Linux: scanner will restart on next cron tick"
    fi
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy — no action needed"
    exit 0
fi

log "STALE: scanner heartbeat is ${age}s old (threshold ${STALE_THRESHOLD}s) — restarting"
_restart_scanner
