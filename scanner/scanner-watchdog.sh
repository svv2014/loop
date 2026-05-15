#!/usr/bin/env bash
# scanner-watchdog.sh — detect a silently-stalled scanner and restart it.
#
# The scanner can become wedged (alive PID, sleep loop intact) while emitting
# no events. This script is run every 5 min (launchd / cron) and checks the
# heartbeat file written by scanner.sh on every tick. If the heartbeat is
# older than LOOP_WATCHDOG_STALE_SECONDS (default: 900 = 15 min, i.e.
# 3× the default 5-min poll interval), the scanner is killed and launchd /
# the OS restarts it automatically.
#
# Usage:
#   scanner/scanner-watchdog.sh   # runs a single check and exits

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK_FILE="/tmp/loop-scanner.lock"
STALE_SECONDS="${LOOP_WATCHDOG_STALE_SECONDS:-900}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

_file_age_seconds() {
    local f="$1"
    local mtime now
    now=$(date +%s)
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    echo $(( now - mtime ))
}

main() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        log "no heartbeat file yet — scanner may not have started; skipping"
        exit 0
    fi

    local age
    age=$(_file_age_seconds "$HEARTBEAT_FILE")

    if [ "$age" -lt "$STALE_SECONDS" ]; then
        log "heartbeat OK (age=${age}s < stale=${STALE_SECONDS}s)"
        exit 0
    fi

    log "STALE: heartbeat age=${age}s >= stale=${STALE_SECONDS}s — restarting scanner"

    # Read scanner PID from lock file and kill it; launchd/cron will restart.
    local pid=""
    if [ -f "$SCANNER_LOCK_FILE" ]; then
        pid=$(cat "$SCANNER_LOCK_FILE" 2>/dev/null || true)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give it 3 seconds to exit cleanly, then force-kill.
        sleep 3
        if kill -0 "$pid" 2>/dev/null; then
            log "PID $pid still alive — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
    else
        log "no live scanner PID found in lock file; cleaning up stale lock"
        rm -f "$SCANNER_LOCK_FILE"
    fi

    log "done — launchd/cron will restart the scanner"
}

main "$@"
