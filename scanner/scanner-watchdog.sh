#!/usr/bin/env bash
# scanner-watchdog.sh — Liveness watchdog for scanner.sh.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh at every tick).
# If the file is missing or its mtime is older than LOOP_SCANNER_WATCHDOG_THRESHOLD
# seconds (default: 900 = 15 min), the scanner is considered wedged:
#   - macOS (launchd): kills the scanner PID so KeepAlive triggers an automatic restart.
#   - Linux (cron):    kills the scanner PID; cron will re-invoke it on the next cycle.
#
# Safe to run even when the scanner is healthy — exits 0 with a log line.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]
#
# Flags:
#   --dry-run   report staleness without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK_FILE="${LOOP_SCANNER_LOCK_FILE:-/tmp/loop-scanner.lock}"
# Default threshold: 15 min (must comfortably exceed the longest possible tick).
# Override in loop.env: LOOP_SCANNER_WATCHDOG_THRESHOLD=<seconds>
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-900}"

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

# _file_age_seconds <path>
# Returns the age of the file in seconds, or a very large number if missing.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "999999"
        return
    fi
    local mtime now
    # stat -f%m is macOS; stat -c%Y is GNU/Linux.
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — read PID from the scanner lock file (if present and alive).
_scanner_pid() {
    [ -f "$SCANNER_LOCK_FILE" ] || return 1
    local pid
    pid=$(cat "$SCANNER_LOCK_FILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s dry-run=${DRY_RUN}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is live — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat is stale (${age}s > ${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID and let the supervisor restart it"
    exit 0
fi

# Remove the stale heartbeat so the next scanner invocation writes a fresh one.
rm -f "$HEARTBEAT_FILE" 2>/dev/null || true

pid=$(_scanner_pid 2>/dev/null || true)
if [ -n "$pid" ]; then
    log "killing scanner PID $pid"
    kill "$pid" 2>/dev/null || true
else
    log "scanner PID not found in $SCANNER_LOCK_FILE — lock may already be stale; removing"
    rm -f "$SCANNER_LOCK_FILE" 2>/dev/null || true
fi

# On Linux without launchd (cron mode), re-invoke the scanner directly in the
# background so it picks up immediately without waiting for the next cron tick.
if [ "$(uname -s)" != "Darwin" ]; then
    log "Linux: relaunching scanner in background"
    nohup "$LOOP_ROOT/scanner/scanner.sh" >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
fi

log "restart triggered"
