#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written each tick by scanner.sh).
# If the file is absent or its recorded epoch is older than STALE_THRESHOLD
# seconds, kills the current scanner PID and kicks the scheduler to restart it.
#
# Designed to run every 5 minutes via launchd (StartInterval=300) or cron.
# On macOS: launchctl kickstart re-launches the KeepAlive scanner service.
# On Linux: killing the PID lets the cron entry restart it on the next tick.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

# Stale threshold: 2× the scanner poll interval. Override LOOP_SCANNER_INTERVAL
# in loop.env to adjust (must match scanner.sh's POLL_INTERVAL).
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

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

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

# _scanner_pid — print the PID from the scanner lock file if the process is alive.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 0
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

# _heartbeat_age_seconds — seconds since the epoch stored in the heartbeat file.
# Falls back to file mtime when the content is not a valid integer.
# Returns a very large number when the file is absent.
_heartbeat_age_seconds() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 999999
        return
    fi
    local now written
    now=$(date +%s)
    written=$(tr -d '[:space:]' < "$HEARTBEAT_FILE" 2>/dev/null || true)
    if [[ "$written" =~ ^[0-9]+$ ]]; then
        echo $(( now - written ))
    else
        local mtime
        mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
                || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
                || echo 0)
        echo $(( now - mtime ))
    fi
}

# _restart_scanner — kill existing PID and kick the scheduler.
_restart_scanner() {
    local pid="$1"
    if [ -n "$pid" ]; then
        log "killing stale scanner PID $pid"
        $DRY_RUN || kill "$pid" 2>/dev/null || true
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
        log "kickstarting com.user.loop-scanner via launchctl"
        $DRY_RUN || launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null || true
    else
        log "scanner PID killed; cron will restart it on next tick"
    fi
}

age=$(_heartbeat_age_seconds)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action needed"
    exit 0
fi

pid=$(_scanner_pid || true)
log "STALE: scanner heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s) — restarting"
_restart_scanner "${pid:-}"
