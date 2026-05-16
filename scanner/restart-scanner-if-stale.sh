#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written every tick by scanner.sh).
# If the file is missing or older than LOOP_SCANNER_WATCHDOG_STALE_SECONDS
# (default: 2 × LOOP_SCANNER_INTERVAL = 10 min), the scanner is considered
# wedged: kill the lock-file PID and let launchd auto-restart it.
#
# Install as a launchd agent (macOS) or cron job (Linux) firing every 5 min.
# Template: templates/launchd/com.user.loop-scanner-watchdog.plist.template
#
# Usage: restart-scanner-if-stale.sh  (no args — reads LOOP_LOG_DIR from loop.env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
MAX_STALE="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-$(( ${LOOP_SCANNER_INTERVAL:-300} * 2 ))}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; no action"
    exit 0
fi

now=$(date +%s)
last=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - last ))

if [ "$age" -lt "$MAX_STALE" ]; then
    log "OK: heartbeat age=${age}s (max=${MAX_STALE}s)"
    exit 0
fi

log "WARN: scanner heartbeat stale — age=${age}s > max_stale=${MAX_STALE}s"

# Kill the running scanner; launchd (KeepAlive=true) will restart it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
    else
        log "lock file present but PID '$pid' is already dead — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file — scanner may have already restarted; no action"
fi
