#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Watchdog for the Loop scanner process.
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat; if the file's mtime is older than
# LOOP_SCANNER_STALE_SECONDS (default 900 = 15 min, i.e. 3× the default poll
# interval), assumes the scanner is silently wedged and kills it so launchd's
# KeepAlive=true restarts it automatically.
#
# Run every 5 minutes via launchd (macOS) or cron (Linux).
# On macOS, launchd restarts the scanner via KeepAlive after the kill.
# On Linux, the next cron --once tick fires within 5 minutes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_SECS="${LOOP_SCANNER_STALE_SECONDS:-900}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner not yet started or heartbeat never written; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_SECS}s"

if [ "$age" -lt "$STALE_SECS" ]; then
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_SECS}s) — restarting"

# Kill the scanner if its PID lock file is present and the holder is alive.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
fi

# On macOS, kick the launchd service explicitly so the restart is immediate.
if command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        || log "WARN: launchctl kickstart failed (KeepAlive will restart on next exit)"
fi

log "watchdog action complete"
