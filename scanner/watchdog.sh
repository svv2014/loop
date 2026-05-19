#!/usr/bin/env bash
# watchdog.sh — Scanner liveness watchdog.
#
# Runs every 5 minutes (via launchd on macOS, cron on Linux).
# Reads the scanner heartbeat file written each tick by scanner.sh.
# If the heartbeat is older than 2 × LOOP_SCANNER_INTERVAL seconds
# (default: 2 × 300 = 600s = 10 min), the scanner is considered wedged
# and its lock-file PID is killed so launchd/cron restarts it.
#
# Usage:
#   watchdog.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE"; }

mkdir -p "$LOOP_LOG_DIR"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
hb_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - hb_mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    exit 0
fi

log "ALERT: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — attempting restart"

if [ ! -f "$SCANNER_LOCK" ]; then
    log "no lock file at $SCANNER_LOCK — scanner not running; nothing to kill"
    exit 0
fi

pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
if [ -z "$pid" ]; then
    log "lock file empty — removing stale lock"
    rm -f "$SCANNER_LOCK"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid already gone — removing stale lock"
    rm -f "$SCANNER_LOCK"
    exit 0
fi

log "killing wedged scanner PID $pid"
kill "$pid" 2>/dev/null || true
sleep 2
if kill -0 "$pid" 2>/dev/null; then
    log "PID $pid still alive after SIGTERM — sending SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$SCANNER_LOCK"
log "scanner restarted (launchd/cron will respawn)"
