#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner when its heartbeat goes stale.
#
# The scanner writes ${LOOP_LOG_DIR}/scanner-heartbeat on every tick.
# This script checks that file's mtime; if it is older than the stale
# threshold (default: 2 × POLL_INTERVAL), the scanner is considered wedged
# and is killed so launchd (macOS) or cron (Linux) can restart it.
#
# Designed to run every 5 minutes via launchd or cron.
#
# Usage:
#   scanner-watchdog.sh            # check and restart if stale
#   scanner-watchdog.sh --dry-run  # report only; no kills

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Default stale threshold: 2 × poll interval + 60s grace.
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE:-$(( POLL_INTERVAL * 2 + 60 ))}"
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
# Returns the age of a file in seconds (now - mtime). Prints 0 if not found.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo 0
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — scanner appears wedged"

# Read the scanner PID from its lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID=${scanner_pid:-unknown} and let launchd/cron restart it"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID=$scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    # Give it 5 s to exit cleanly; force-kill if still alive.
    sleep 5
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "scanner still alive after SIGTERM — sending SIGKILL"
        kill -9 "$scanner_pid" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE"
    log "scanner killed; launchd/cron will restart it automatically"
else
    # No live scanner PID found — lock file may be stale; remove it so a
    # fresh scanner can start on the next launchd/cron trigger.
    log "no live scanner PID (lock=${scanner_pid:-empty}); removing stale lock"
    rm -f "$LOCK_FILE"
fi
