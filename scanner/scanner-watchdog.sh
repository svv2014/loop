#!/usr/bin/env bash
# scanner-watchdog.sh — restart a wedged scanner process.
#
# Reads the heartbeat file written by scanner.sh on every tick. If the file
# is older than LOOP_SCANNER_STALE_SECONDS (default: 2 × poll interval), the
# scanner is considered wedged. The watchdog kills the scanner PID from the
# lock file and, on macOS, issues a launchctl kickstart to restart it.
# launchd's KeepAlive=true would restart it anyway on exit, so the kill alone
# is sufficient; kickstart is belt-and-suspenders for faster recovery.
#
# Usage:
#   scanner-watchdog.sh           # one-shot check (run via launchd/cron every 5 min)
#   scanner-watchdog.sh --dry-run # report stale state without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
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

# _file_age_seconds <path>
# Returns the age of the file in seconds, or a very large number if it does not exist.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "999999"
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=$HEARTBEAT_FILE"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat is stale (age=${age}s > threshold=${STALE_THRESHOLD}s)"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${scanner_pid:-<unknown>} and trigger restart"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    sleep 2
else
    log "scanner PID ${scanner_pid:-<unknown>} not alive — lock file stale or missing"
    rm -f "$LOCK_FILE"
fi

# On macOS, kickstart the launchd service so it restarts immediately rather
# than waiting for KeepAlive's ThrottleInterval.
if command -v launchctl >/dev/null 2>&1; then
    local_uid=$(id -u)
    if launchctl kickstart -k "gui/${local_uid}/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart triggered for com.user.loop-scanner"
    else
        log "launchctl kickstart failed or not applicable — launchd will restart on next ThrottleInterval"
    fi
fi

log "restart triggered — watchdog done"
