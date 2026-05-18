#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a wedged scanner.
#
# A scanner is wedged when its heartbeat file has not been updated for longer
# than LOOP_SCANNER_STALE_THRESHOLD seconds (default: 2 × poll_interval = 600s).
# The scanner writes this file at the top of every tick via run_once().
#
# Recovery: send SIGTERM to the scanner PID from the lock file so launchd
# (KeepAlive=true) auto-restarts it. On Linux the script is idempotent — cron
# restarts the scanner on its next scheduled interval after the PID is gone.
#
# Run via launchd every 5 min (StartInterval=300) on macOS, or cron (*/5) on Linux.
#
# Flags:
#   --dry-run   report what would happen without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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
# Prints the age of the file in seconds (now - mtime), or "" if not found.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { printf ''; return; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || printf '')
    [ -z "$mtime" ] && { printf ''; return; }
    now=$(date +%s)
    printf '%s' "$(( now - mtime ))"
}

log "check (stale_threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file — scanner not yet started or completing first tick"
    exit 0
fi

age=$(_file_age_seconds "$HEARTBEAT_FILE")
if [ -z "$age" ]; then
    log "could not stat heartbeat file — skipping"
    exit 0
fi

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok (heartbeat fresh)"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — initiating restart"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let launchd restart"
    exit 0
fi

pid=""
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "sending SIGTERM to wedged scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        log "SIGKILL sent to PID $pid (did not exit after SIGTERM)"
    fi
else
    log "no live scanner PID in lock file — removing stale lock so next start can acquire it"
    rm -f "$LOCK_FILE"
fi

log "restart triggered — launchd/cron will restart the scanner"
