#!/usr/bin/env bash
# scanner/watchdog.sh — Scanner liveness watchdog.
# Fires every 5 minutes (launchd StartInterval=300 or cron */5).
# If the scanner heartbeat file is older than LOOP_SCANNER_STALE_THRESHOLD
# seconds (default 900 = 15 min), kills the scanner PID so launchd or the
# next cron tick can start a fresh instance.
#
# Usage: watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -10; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOG="${LOOP_LOG_DIR}/loop-scanner.log"
SCANNER_LOCK="/tmp/loop-scanner.lock"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-900}"

# _mtime_age <file>
# Returns seconds since the file was last modified, or a large number if absent.
_mtime_age() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo "999999"
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

heartbeat_age=$(_mtime_age "$HEARTBEAT_FILE")
log_age=$(_mtime_age "$SCANNER_LOG")

log "heartbeat_age=${heartbeat_age}s  log_age=${log_age}s  threshold=${STALE_THRESHOLD}s"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat is ${heartbeat_age}s old (> ${STALE_THRESHOLD}s) — scanner may be wedged"

# Read the scanner PID from the lock file.
scanner_pid=""
if [ -f "$SCANNER_LOCK" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if $DRY_RUN; then
    if [ -n "$scanner_pid" ]; then
        log "DRY-RUN: would kill scanner PID $scanner_pid"
    else
        log "DRY-RUN: no scanner lock found — nothing to kill"
    fi
    exit 0
fi

if [ -z "$scanner_pid" ]; then
    log "no scanner lock file found — scanner is not running; launchd/cron will start it"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already gone — removing stale lock"
    rm -f "$SCANNER_LOCK"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid"
kill "$scanner_pid" 2>/dev/null || true

# On macOS with KeepAlive=true, launchd restarts the scanner automatically.
# On Linux (cron every 5 min), clearing the lock unblocks the next cron tick.
log "scanner killed — launchd/cron will restart it"
