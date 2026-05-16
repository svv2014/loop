#!/usr/bin/env bash
# scanner-watchdog.sh — kill a wedged scanner so launchd/cron restarts it.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is absent or its mtime
# is older than STALE_THRESHOLD_SECONDS (default: 2 × LOOP_SCANNER_INTERVAL,
# i.e. 2 × 300 = 600 s), the scanner is considered wedged.
#
# On macOS:  sends SIGTERM to the PID in /tmp/loop-scanner.lock, then waits
#            up to 10 s for it to die; falls back to SIGKILL.
#            launchd (KeepAlive=true) restarts the scanner automatically.
#
# On Linux:  same PID-kill logic; cron or a separate restart daemon handles
#            re-launch.
#
# Run every 5 min via launchd StartInterval or cron */5.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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
# Returns the age of <path> in seconds, or a very large number if absent.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive (heartbeat age=${age}s, threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: heartbeat stale for ${age}s (threshold=${STALE_THRESHOLD}s) — scanner appears wedged"

# Read scanner PID from lock file.
pid=""
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -z "$pid" ]; then
    log "no lock file / empty PID — scanner is not running; launchd will restart it"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "PID $pid is already dead — launchd will restart scanner"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would send SIGTERM to scanner PID $pid"
    exit 0
fi

log "sending SIGTERM to scanner PID $pid"
kill -TERM "$pid" 2>/dev/null || true

# Wait up to 10 s for graceful exit, then SIGKILL.
local_wait=0
while kill -0 "$pid" 2>/dev/null && [ "$local_wait" -lt 10 ]; do
    sleep 1
    local_wait=$(( local_wait + 1 ))
done

if kill -0 "$pid" 2>/dev/null; then
    log "WARN: PID $pid did not exit after ${local_wait}s; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
fi

log "scanner killed — launchd/cron will restart it"
