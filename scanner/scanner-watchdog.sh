#!/usr/bin/env bash
# scanner-watchdog.sh — Restart the scanner if its heartbeat is stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner at each tick start).
# If the file's mtime is older than LOOP_SCANNER_WATCHDOG_THRESHOLD seconds
# (default: 2 × LOOP_SCANNER_INTERVAL = 600s), kills the scanner PID (read from
# /tmp/loop-scanner.lock) and lets launchd (KeepAlive) or cron restart it.
#
# Run every 5 minutes via launchd (macOS) or cron (Linux).
# Safe to run while the scanner is healthy — does nothing when heartbeat is fresh.
#
# Simulate a wedge for manual testing:
#   kill -STOP $SCANNER_PID   # pause scanner without killing it
#   # wait > THRESHOLD seconds, watchdog should kill+restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

log "tick (threshold=${THRESHOLD}s)"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — scanner may not have started yet"
    exit 0
fi

heartbeat_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( $(date +%s) - heartbeat_mtime ))

if [ "$age" -lt "$THRESHOLD" ]; then
    log "heartbeat ok (age=${age}s, threshold=${THRESHOLD}s)"
    exit 0
fi

log "STALE heartbeat (age=${age}s >= threshold=${THRESHOLD}s) — restarting scanner"

# Kill the scanner if the lock file records a live PID.
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
        log "sending SIGTERM to scanner PID ${scanner_pid}"
        kill "$scanner_pid" 2>/dev/null || true
        sleep 2
    fi
fi

# On macOS with launchd: kickstart so the scanner restarts immediately via
# KeepAlive rather than waiting for the next ThrottleInterval window.
# On Linux: killing the cron-started process is sufficient; cron restarts on
# the next */5 tick.
if command -v launchctl >/dev/null 2>&1; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart: scanner restarted"
    else
        log "launchctl kickstart failed — scanner will restart via KeepAlive or next cron tick"
    fi
fi

log "watchdog done"
