#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat is stale.
#
# Runs every 5 min via launchd (macOS) or cron (Linux). If the heartbeat
# file (${LOOP_LOG_DIR}/scanner-heartbeat) has not been touched for more
# than LOOP_SCANNER_WATCHDOG_THRESHOLD seconds (default: 2 × poll interval,
# i.e. 600s), the scanner is considered wedged. The watchdog kills the PID
# recorded in /tmp/loop-scanner.lock and lets the scheduler restart it.
#
# On macOS with KeepAlive=true in the launchd plist, launchd auto-restarts
# the scanner within seconds of the kill. On Linux the next cron invocation
# fires within 5 min.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# heartbeat_age_seconds — returns the age of the heartbeat file in seconds,
# or a large value (9999999) if the file does not exist.
heartbeat_age_seconds() {
    [ -f "$HEARTBEAT_FILE" ] || { echo 9999999; return; }
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || { echo 9999999; return; })
    now=$(date +%s)
    echo $(( now - mtime ))
}

log "check: threshold=${THRESHOLD}s heartbeat=${HEARTBEAT_FILE}"

age=$(heartbeat_age_seconds)
log "heartbeat age=${age}s"

if [ "$age" -lt "$THRESHOLD" ]; then
    log "scanner is healthy (age=${age}s < threshold=${THRESHOLD}s)"
    exit 0
fi

log "WARN: heartbeat stale for ${age}s (threshold=${THRESHOLD}s) — scanner may be wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let scheduler restart it"
    exit 0
fi

# Read the scanner PID from the lock file.
if [ ! -f "$LOCK_FILE" ]; then
    log "WARN: lock file $LOCK_FILE not found — scanner may already be stopped; skipping kill"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
if [ -z "$pid" ]; then
    log "WARN: lock file empty — skipping kill"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "WARN: scanner PID $pid is not alive — lock is already stale"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "killing wedged scanner PID $pid"
kill "$pid" 2>/dev/null || true

# Give launchd / cron up to 5s to release the lock file, then clean it up
# ourselves so the next invocation is not blocked by a stale lock.
local_wait=0
while [ -f "$LOCK_FILE" ] && [ "$local_wait" -lt 5 ]; do
    sleep 1
    local_wait=$(( local_wait + 1 ))
done
if [ -f "$LOCK_FILE" ]; then
    log "lock file still present after kill — removing to unblock restart"
    rm -f "$LOCK_FILE"
fi

log "scanner killed; scheduler will restart it automatically"
