#!/usr/bin/env bash
# scanner-watchdog.sh — Restart the scanner if its heartbeat file becomes stale.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# On macOS the scanner has KeepAlive=true in its plist, so killing it causes
# launchd to restart it automatically. On Linux the cron job re-invokes it.
#
# The scanner writes ${LOOP_LOG_DIR}/scanner-heartbeat at the start of every
# tick. If that file is older than 2× LOOP_SCANNER_INTERVAL (default 600s),
# the scanner is considered wedged and is killed so it can be restarted.
#
# Usage:
#   scanner-watchdog.sh            # normal mode
#   scanner-watchdog.sh --dry-run  # print what would happen without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2× the poll interval (default 600s / 10 min).
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

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
# Returns the age of the file in seconds (now - mtime).
_file_age_seconds() {
    local path="$1"
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null) \
        || mtime=$(stat -c%Y "$path" 2>/dev/null) \
        || { echo 999999; return 1; }
    now=$(date +%s)
    echo $(( now - mtime ))
}

log "checking scanner liveness (threshold=${STALE_THRESHOLD}s)"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file at ${HEARTBEAT_FILE} — scanner may not have started yet"
    exit 0
fi

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner alive (heartbeat=${age}s ago)"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s threshold)"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${scanner_pid:-unknown} and remove lock"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing stale scanner PID ${scanner_pid}"
    kill "$scanner_pid" 2>/dev/null || true
    log "scanner killed — launchd/cron will restart it"
else
    log "WARN: no live scanner process found (lock=${LOCK_FILE} pid=${scanner_pid:-empty})"
    # Remove stale lock so the next scanner invocation is not blocked.
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log "removed stale lock file"
    fi
fi
