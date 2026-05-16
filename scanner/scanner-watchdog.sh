#!/usr/bin/env bash
# scanner-watchdog.sh — Restart a silently-wedged scanner.
#
# Checks the mtime of ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is older
# than LOOP_SCANNER_STALE_THRESHOLD seconds (default: 2 × poll interval = 600s)
# the scanner is considered wedged: its PID is killed and launchd/cron will
# restart it. If no heartbeat file exists yet the watchdog exits quietly so it
# does not fire before the first scanner tick completes.
#
# Usage (called by launchd StartInterval or cron every 5 min):
#   scanner-watchdog.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# No heartbeat file → scanner never started or just restarted; nothing to do.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file — scanner not yet started, exiting"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s — scanner alive"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — scanner appears wedged"

# Read the scanner PID from its lock file and kill it.
if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file found — scanner may have already exited; removing stale heartbeat"
    rm -f "$HEARTBEAT_FILE"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$pid" ]; then
    log "lock file empty — removing and clearing heartbeat"
    rm -f "$LOCK_FILE" "$HEARTBEAT_FILE"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid is already dead — removing stale lock and heartbeat"
    rm -f "$LOCK_FILE" "$HEARTBEAT_FILE"
    exit 0
fi

log "killing wedged scanner PID $pid (launchd/cron will restart it)"
kill "$pid" 2>/dev/null || true
# Remove the heartbeat so the next scanner tick writes a fresh one; if the
# watchdog fires again before the scanner has done its first tick the missing-
# file guard above will suppress a second kill attempt.
rm -f "$HEARTBEAT_FILE"
log "done — scanner PID $pid signalled"
