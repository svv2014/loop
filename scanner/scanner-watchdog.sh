#!/usr/bin/env bash
# scanner-watchdog.sh — restart a wedged scanner process.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is absent or its mtime
# is older than STALE_THRESHOLD_SECONDS, the scanner is considered wedged:
# the lock-file PID is killed (SIGTERM → SIGKILL) and launchd / cron restarts it.
#
# Designed to run every 5 min via launchd (StartInterval) or cron. It is safe
# to run while the scanner is healthy — a fresh heartbeat means no action taken.
#
# Environment / tunables (via loop.env):
#   LOOP_SCANNER_INTERVAL        poll interval in seconds (default 300)
#   LOOP_WATCHDOG_STALE_MULT     staleness = MULT × INTERVAL (default 2)
#   LOOP_WATCHDOG_KILL_GRACE     seconds between SIGTERM and SIGKILL (default 10)
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_MULT="${LOOP_WATCHDOG_STALE_MULT:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_MULT ))
KILL_GRACE="${LOOP_WATCHDOG_KILL_GRACE:-10}"
LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"

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

# _heartbeat_age — prints seconds since the heartbeat file was last written,
# or a very large number if the file is absent.
_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 999999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y  "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — read PID from lock file; empty if absent or unreadable.
_scanner_pid() {
    cat "$LOCK_FILE" 2>/dev/null || true
}

# _kill_scanner <pid> — SIGTERM, wait, then SIGKILL if still alive.
_kill_scanner() {
    local pid="$1"
    log "sending SIGTERM to scanner PID $pid"
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt "$KILL_GRACE" ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
        i=$(( i + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        log "scanner PID $pid still alive after ${KILL_GRACE}s — sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE"
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action"
    exit 0
fi

pid=$(_scanner_pid)

if [ -z "$pid" ]; then
    log "WARN: heartbeat stale (${age}s) but no lock file — scanner may have exited; launchd will restart"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "WARN: heartbeat stale (${age}s) and PID $pid is dead — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

log "ALERT: scanner wedged — heartbeat=${age}s > threshold=${STALE_THRESHOLD}s, PID=$pid"
if $DRY_RUN; then
    log "DRY-RUN: would kill PID $pid and let launchd restart"
    exit 0
fi

_kill_scanner "$pid"
log "scanner killed; launchd/cron will restart it automatically"
