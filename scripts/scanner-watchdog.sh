#!/usr/bin/env bash
# scanner-watchdog.sh — detect and recover a wedged scanner process.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat; if its mtime is older than
# LOOP_SCANNER_WATCHDOG_THRESHOLD seconds (default: 2 × poll interval = 10 min)
# the scanner is considered wedged. The watchdog kills the PID recorded in
# /tmp/loop-scanner.lock and exits, allowing launchd (KeepAlive=true) to
# restart the scanner automatically.
#
# Designed to run every 5 min via launchd / cron. Safe to run concurrently
# with the scanner — it only signals a process, never modifies shared state.
#
# Flags:
#   --dry-run   report what would be done, do not kill anything
#   --once      single check (default; reserved for future loop mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="${LOOP_SCANNER_LOCK_FILE:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;  # default; reserved
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age_seconds <path>
# Returns the number of seconds since the file was last modified.
# Falls back to a very large number (effectively infinite age) if the
# file does not exist or stat is unavailable.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo 999999; return; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

log "check (threshold=${THRESHOLD}s dry-run=${DRY_RUN})"

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s (file: ${HEARTBEAT_FILE})"

if [ "$age" -lt "$THRESHOLD" ]; then
    log "scanner is alive — nothing to do"
    exit 0
fi

# Heartbeat is stale — scanner is wedged or has never started.
log "WARN: heartbeat stale for ${age}s (threshold=${THRESHOLD}s) — scanner may be wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file at ${LOCK_FILE} — scanner not running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file empty — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID ${scanner_pid} is already dead — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${scanner_pid}"
    exit 0
fi

log "killing wedged scanner PID ${scanner_pid} — launchd will restart"
kill "$scanner_pid" 2>/dev/null || true

log "done"
