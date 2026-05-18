#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Scanner liveness watchdog.
#
# Reads the heartbeat file written by scanner.sh on every tick.
# If the heartbeat is older than STALE_THRESHOLD seconds, kills the
# scanner PID from the lock file so launchd (macOS) or cron (Linux)
# restarts it.
#
# Usage:
#   restart-scanner-if-stale.sh           # run once (intended for launchd/cron)
#
# Environment (all optional — sensible defaults shown):
#   LOOP_LOG_DIR          — log directory (default: ~/.loop/logs)
#   LOOP_SCANNER_INTERVAL — poll interval in seconds (default: 300)
#   LOOP_WATCHDOG_MULTIPLIER — staleness = INTERVAL * MULTIPLIER (default: 3)
#
# macOS: launchd fires this every 5 min (StartInterval 300).
# Linux: cron runs */5 entry; see install.sh for the exact line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
MULTIPLIER="${LOOP_WATCHDOG_MULTIPLIER:-3}"
STALE_THRESHOLD=$(( POLL_INTERVAL * MULTIPLIER ))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE"; }

log "check: heartbeat=${HEARTBEAT_FILE} stale_after=${STALE_THRESHOLD}s"

# No heartbeat file yet — scanner may have never started or is starting up now.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — skipping (scanner may not have run yet)"
    exit 0
fi

# Compute age using stat; support both macOS (-f%m) and Linux (-c%Y).
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo 0)
now=$(date +%s)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — restarting scanner"

# Kill the scanner PID from its lock file.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give launchd/cron a moment to notice and restart.
        sleep 2
    else
        log "lock file present but PID '${pid}' is not alive — removing lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file at $LOCK_FILE — scanner may already be dead"
fi

# On Linux (no launchd KeepAlive) start a fresh scanner in the background.
# On macOS, launchd's KeepAlive=true restarts it automatically after the kill.
if [ "$(uname -s)" != "Darwin" ]; then
    log "Linux: launching scanner in background"
    nohup "$LOOP_ROOT/scanner/scanner.sh" >> "$LOOP_LOG_DIR/loop-scanner.log" 2>&1 &
    log "Linux: scanner started (PID $!)"
fi
