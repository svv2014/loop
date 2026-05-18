#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops emitting heartbeats.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written every tick by scanner.sh).
# If the file is missing or its mtime is older than LOOP_SCANNER_HEARTBEAT_TIMEOUT
# seconds (default: 2 × LOOP_SCANNER_INTERVAL, i.e. 10 min), the scanner is
# considered wedged and killed so launchd/cron can restart it.
#
# Designed to run every 5 min via launchd StartInterval or a cron entry.
#
# Flags:
#   --dry-run   report stale/ok status without killing the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
HEARTBEAT_TIMEOUT="${LOOP_SCANNER_HEARTBEAT_TIMEOUT:-$(( POLL_INTERVAL * 2 ))}"
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
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "999999"
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age)

if [ "$age" -lt "$HEARTBEAT_TIMEOUT" ]; then
    log "ok: heartbeat age=${age}s < timeout=${HEARTBEAT_TIMEOUT}s"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= timeout=${HEARTBEAT_TIMEOUT}s)"

if $DRY_RUN; then
    log "dry-run: would kill scanner"
    exit 0
fi

# Read the scanner PID from the lock file and kill it; launchd/cron restarts it.
if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file at $LOCK_FILE — scanner may already be dead"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "empty lock file — nothing to kill"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid already dead — lock is stale"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid"
kill "$scanner_pid" 2>/dev/null || true
# Give launchd a moment to notice before the watchdog exits.
sleep 2
log "done — launchd will restart the scanner"
