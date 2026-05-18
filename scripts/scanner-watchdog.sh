#!/usr/bin/env bash
# scanner-watchdog.sh — detect and recover a silently-wedged scanner process.
#
# The scanner can become stuck (alive PID, sleep loop intact) but emit no
# events for an extended period. This script checks the mtime of the
# scanner-heartbeat file that scanner.sh updates on every tick. If the file
# is older than STALE_THRESHOLD_SECONDS, the scanner is killed; launchd
# (macOS) or cron (Linux) will restart it automatically.
#
# Designed to run every 5 minutes via launchd StartInterval or cron.
#
# Flags:
#   --dry-run   report stale state without killing the process
#   --help      show usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Kill the scanner if heartbeat is older than 2× the poll interval.
STALE_THRESHOLD_SECONDS=$(( POLL_INTERVAL * 2 ))

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

# _heartbeat_age_seconds — returns age of the heartbeat file in seconds,
# or a very large number if the file is absent.
_heartbeat_age_seconds() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age_seconds)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD_SECONDS}s"

if [ "$age" -lt "$STALE_THRESHOLD_SECONDS" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner heartbeat is stale (${age}s > ${STALE_THRESHOLD_SECONDS}s)"

# Read the scanner PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -z "$scanner_pid" ]; then
    log "no scanner lock file — scanner may already be restarting"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already gone — launchd/cron will restart it"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $scanner_pid"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid (launchd/cron will restart)"
kill "$scanner_pid" 2>/dev/null || true
