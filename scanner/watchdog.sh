#!/usr/bin/env bash
# scanner/watchdog.sh — Liveness watchdog for the Loop scanner.
#
# Fires on a short cadence (every 5 min via launchd StartInterval or cron */5).
# Checks scanner-heartbeat mtime; if older than 2x LOOP_SCANNER_INTERVAL the
# scanner is presumed wedged — kills the PID and lets launchd/cron restart it.
#
# The heartbeat file is written by scanner.sh at the top of every tick.
#
# Usage:
#   scanner/watchdog.sh               # normal execution
#   DRY_RUN=true scanner/watchdog.sh  # print what would happen, no kills

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2x poll interval (default 10 min)
MAX_STALE_SECONDS=$(( POLL_INTERVAL * 2 ))
DRY_RUN="${DRY_RUN:-false}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file yet — skipping (scanner may not have run)"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -le "$MAX_STALE_SECONDS" ]; then
    log "heartbeat age=${age}s <= ${MAX_STALE_SECONDS}s — scanner alive"
    exit 0
fi

log "STALE: heartbeat age=${age}s > ${MAX_STALE_SECONDS}s — triggering restart"

if [ "$DRY_RUN" = "true" ]; then
    log "DRY_RUN: would kill scanner and request restart"
    exit 0
fi

# Kill via lock file PID.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "sending SIGTERM to scanner PID $pid"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            log "SIGTERM ignored — sending SIGKILL to PID $pid"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    else
        log "PID $pid from lock file is not running"
    fi
    rm -f "$LOCK_FILE"
fi

# Request restart from the process supervisor.
if [ "$(uname -s)" = "Darwin" ]; then
    local_uid=$(id -u)
    if launchctl kickstart -k "gui/${local_uid}/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart issued — scanner will restart"
    else
        log "launchctl kickstart failed — KeepAlive will restart on next exit"
    fi
else
    log "Linux: scanner will be restarted by cron on next */5 tick"
fi
