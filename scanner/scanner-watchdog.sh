#!/usr/bin/env bash
# scanner-watchdog.sh — restart a silently-wedged scanner.
#
# Reads the heartbeat file written by scanner.sh every tick.
# If the file is missing or its mtime is older than LOOP_SCANNER_STALE_THRESHOLD
# seconds (default 900 = 15 min = 3× the 300 s poll interval), the scanner is
# considered wedged and is restarted via launchctl kickstart (macOS) or by
# killing the lock-file PID (Linux).
#
# Usage (run every 5 min via launchd StartInterval or cron):
#   scanner/scanner-watchdog.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="${LOOP_LOG_DIR}/loop-scanner.lock"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-900}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

_scanner_pid() {
    cat "$LOCK_FILE" 2>/dev/null || true
}

_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 99999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

_restart_scanner() {
    local pid="$1"
    log "Restarting wedged scanner (PID=${pid:-unknown})"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
    if command -v launchctl >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — scanner will restart on next KeepAlive cycle"
    else
        log "INFO: no launchctl; scanner will be re-spawned by cron on next tick"
    fi
}

age=$(_heartbeat_age)
pid=$(_scanner_pid)

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "OK: heartbeat age=${age}s (threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "WARN: heartbeat file missing — scanner may not have started yet (threshold=${STALE_THRESHOLD}s)"
else
    log "STALE: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — scanner appears wedged"
fi

_restart_scanner "$pid"
