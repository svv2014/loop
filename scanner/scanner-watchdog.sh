#!/usr/bin/env bash
# scanner-watchdog.sh — detect a wedged scanner and restart it.
#
# Runs every 5 minutes (launchd StartInterval or cron */5). Reads the
# scanner heartbeat file written by run_once() on every tick. If the
# file has not been updated within STALE_THRESHOLD seconds, the scanner
# is considered wedged: its PID is killed so launchd can restart it.
#
# Environment:
#   LOOP_SCANNER_STALE_SECONDS  — max tolerable silence (default: 900, i.e. 3× a 300s interval)
#   LOOP_SCANNER_LOCK_FILE      — scanner lock file path (default: /tmp/loop-scanner.lock)
#   LOOP_LOG_DIR                — loop log directory (loaded from loop.env)
#
# Usage:
#   scanner-watchdog.sh            # normal run (invoked by launchd/cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK_FILE:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_SECONDS:-900}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file missing — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s — scanner is healthy"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s) — scanner may be wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file at $LOCK_FILE — scanner not running; nothing to kill"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$pid" ]; then
    log "lock file empty — cannot determine scanner PID"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid is already gone — launchd should restart it"
    exit 0
fi

log "killing wedged scanner PID $pid (SIGTERM)"
kill -TERM "$pid" 2>/dev/null || true
# Give it 5s to exit cleanly before SIGKILL.
sleep 5
if kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid did not exit — sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
fi
log "scanner PID $pid killed — launchd will restart it"
