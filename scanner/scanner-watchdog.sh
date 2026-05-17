#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat is stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file's mtime is older than
# STALE_THRESHOLD seconds (default: 2 × POLL_INTERVAL = 600s), the scanner is
# considered wedged. The lock file at /tmp/loop-scanner.lock is read for the
# scanner PID; if that PID is alive it is killed so launchd (KeepAlive=true)
# restarts the scanner automatically.
#
# Designed to run every 5 minutes via launchd StartInterval or cron.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
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
# Prints seconds since the file was last modified. Prints -1 if the file does not exist.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo -1
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

heartbeat_age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$heartbeat_age" -lt 0 ]; then
    log "heartbeat file missing — scanner may not have started yet; skipping"
    exit 0
fi

log "heartbeat age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "STALE: scanner heartbeat is ${heartbeat_age}s old (threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    log "DRY-RUN: would kill scanner PID ${scanner_pid:-<unknown>} and allow launchd to restart it"
    exit 0
fi

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file found — scanner is not running; launchd will restart it"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file is empty — removing and allowing launchd to restart"
    rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already dead — launchd will restart it"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid — launchd (KeepAlive=true) will restart it"
kill "$scanner_pid" || true
# Give launchd a moment to notice the exit; the watchdog itself does not restart
# the scanner directly — that is launchd's job.
sleep 2
if kill -0 "$scanner_pid" 2>/dev/null; then
    log "WARN: PID $scanner_pid still alive after SIGTERM — sending SIGKILL"
    kill -9 "$scanner_pid" || true
fi
log "done — scanner will be restarted by launchd"
