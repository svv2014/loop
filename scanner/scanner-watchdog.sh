#!/usr/bin/env bash
# scanner-watchdog.sh — restart a wedged scanner process.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh on every tick).
# If the file is absent or its mtime is older than LOOP_SCANNER_WATCHDOG_STALE_SECS
# (default: 2 × LOOP_SCANNER_INTERVAL = 600s), the scanner is considered wedged:
# the PID recorded in the lock file is killed so launchd/cron restarts it.
#
# Designed to run every 5 minutes via launchd (StartInterval 300) or cron.
#
# Usage:
#   scanner-watchdog.sh            # check and restart if stale
#   scanner-watchdog.sh --dry-run  # check only, print status, do not kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_SECS="${LOOP_SCANNER_WATCHDOG_STALE_SECS:-$(( POLL_INTERVAL * 2 ))}"

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
# Returns seconds since the file's mtime, or a large number if the file
# does not exist (triggering the stale check).
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo 999999; return; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s stale_threshold=${STALE_SECS}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_SECS" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner appears wedged (heartbeat ${age}s old > ${STALE_SECS}s threshold)"

# Read the scanner PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID=${scanner_pid:-unknown} and let launchd restart it"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID=$scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    # Give launchd a moment; it will restart via KeepAlive.
    sleep 2
    log "scanner killed — launchd will restart it"
else
    log "no live scanner PID found (lock_file=${LOCK_FILE} pid=${scanner_pid:-none})"
    # Remove stale heartbeat so the next watchdog tick does not false-alarm
    # once the scanner restarts and a fresh heartbeat appears.
    rm -f "$HEARTBEAT_FILE" 2>/dev/null || true
fi
