#!/usr/bin/env bash
# scanner-watchdog.sh — Liveness watchdog for the scanner process.
#
# Checks scanner-heartbeat mtime each run. If the heartbeat file is older than
# LOOP_SCANNER_WATCHDOG_THRESHOLD (default: 2 × poll interval + 60 s = 660 s),
# the scanner is considered wedged: its PID is killed so launchd (macOS) or the
# cron re-invocation restarts it automatically.
#
# Usage (macOS — managed by launchd, StartInterval=300):
#   Installed automatically by install.sh --bootstrap as com.user.loop-scanner-watchdog
#
# Usage (Linux — cron):
#   */5 * * * * /path/to/loop/scanner/scanner-watchdog.sh >> /path/to/logs/loop-scanner-watchdog.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Default threshold: 2 poll cycles + 60 s grace.  Override via env for tests.
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 + 60 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — scanner not yet started or running in dry-run mode; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$THRESHOLD" ]; then
    log "heartbeat age=${age}s threshold=${THRESHOLD}s — scanner healthy"
    exit 0
fi

log "ALERT: heartbeat stale (age=${age}s > threshold=${THRESHOLD}s) — scanner may be wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file found — scanner not running; nothing to kill"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$pid" ]; then
    log "lock file empty — skipping kill"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid is already dead; launchd/cron will restart it"
    exit 0
fi

log "sending SIGTERM to wedged scanner (PID $pid)"
kill "$pid" || true

# On Linux there is no launchd to auto-restart.  Spawn a fresh scanner in the
# background so the pipeline resumes without waiting for the next cron tick.
if [ "$(uname -s)" != "Darwin" ]; then
    sleep 2
    log "Linux mode — spawning replacement scanner"
    nohup "$LOOP_ROOT/scanner/scanner.sh" >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
fi
