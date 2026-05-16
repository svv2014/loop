#!/usr/bin/env bash
# scanner-watchdog.sh — detect a wedged scanner and restart it.
#
# The scanner writes a heartbeat timestamp to ${LOOP_LOG_DIR}/scanner-heartbeat
# on every tick. This watchdog checks that file's mtime; if it is older than
# STALE_THRESHOLD seconds (default 2× POLL_INTERVAL = 600s) the scanner is
# considered wedged, its PID is killed, and launchd/cron restarts it.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
#
# Usage:
#   scanner-watchdog.sh [--dry-run]
#
# Environment:
#   LOOP_SCANNER_INTERVAL   poll cadence in seconds (default 300)
#   LOOP_WATCHDOG_THRESHOLD override stale threshold in seconds
#   LOOP_LOG_DIR            log directory (loaded from loop.env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

# _file_age_seconds <path>
# Returns how many seconds ago the file was last modified, or "" if not found.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo ""; return 0; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo "")
    [ -z "$mtime" ] && { echo ""; return 0; }
    now=$(date +%s)
    echo $(( now - mtime ))
}

log "tick (threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

# If no heartbeat file exists yet, the scanner may never have started — skip.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — scanner may not have run yet; skipping"
    exit 0
fi

age=$(_file_age_seconds "$HEARTBEAT_FILE")
if [ -z "$age" ]; then
    log "could not read heartbeat mtime — skipping"
    exit 0
fi

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner appears wedged (heartbeat ${age}s old, threshold ${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# Kill the scanner PID recorded in the lock file so launchd/cron restarts it.
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
        log "killing wedged scanner PID $scanner_pid"
        kill "$scanner_pid" 2>/dev/null || true
        sleep 2
        # Force-kill if still alive.
        if kill -0 "$scanner_pid" 2>/dev/null; then
            log "WARN: PID $scanner_pid still alive after SIGTERM — sending SIGKILL"
            kill -9 "$scanner_pid" 2>/dev/null || true
        fi
    else
        log "lock file exists but PID '${scanner_pid:-}' is not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file found — scanner not running; nothing to kill"
fi

# On macOS with launchd KeepAlive=true the scanner restarts automatically after
# the kill above. On Linux with cron the next cron tick launches a fresh scanner.
log "scanner restart triggered"
