#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the heartbeat mtime is older than STALE_THRESHOLD seconds, kills the scanner
# PID from the lock file and lets launchd/cron restart it automatically.
#
# Usage:
#   scanner-watchdog.sh            # runs a single check (suitable for launchd StartInterval or cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Kill scanner if heartbeat is older than 2× the poll interval.
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# Heartbeat file must exist and be writable before we can check it.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have run yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat ok (age=${age}s < threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s) — restarting scanner"

# Kill the scanner process recorded in the lock file.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give launchd/cron a moment to clean up before we remove the lock.
        sleep 2
    fi
    rm -f "$LOCK_FILE"
fi

# On macOS, ask launchd to restart the scanner immediately.
if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
    if launchctl list 2>/dev/null | grep -q "com.user.loop-scanner"; then
        log "kickstarting com.user.loop-scanner via launchctl"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl start com.user.loop-scanner 2>/dev/null \
            || log "WARN: launchctl restart failed — launchd will restart on its own"
    fi
fi

# On Linux the scanner is managed by cron (--once per tick) so no explicit
# restart is needed — just clearing the lock file is sufficient.

log "watchdog action complete"
