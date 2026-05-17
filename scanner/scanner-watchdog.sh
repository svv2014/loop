#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops emitting heartbeats.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file is absent or older than LOOP_WATCHDOG_STALE_SECS (default 900s),
# the scanner is considered wedged: kill it and let launchd/cron restart it.
#
# Usage (run every 5 min via launchd/cron — see install.sh):
#   scanner-watchdog.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_SECS="${LOOP_WATCHDOG_STALE_SECS:-900}"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

_scanner_pid() {
    local pid=""
    if [ -f "$LOCK_FILE" ]; then
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    fi
    printf '%s' "$pid"
}

_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        printf '%s' "999999"
        return
    fi
    local mtime now age
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))
    printf '%s' "$age"
}

_restart_scanner() {
    # Try launchctl kickstart (macOS) first; fall back to direct exec (Linux/cron).
    if command -v launchctl >/dev/null 2>&1 && launchctl list com.user.loop-scanner >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl stop com.user.loop-scanner 2>/dev/null \
            || true
        log "restarted via launchctl kickstart"
    else
        # Linux / non-launchd: launch scanner in the background.
        # cron will restart it on the next tick regardless; this gives faster recovery.
        nohup "$LOOP_ROOT/scanner/scanner.sh" >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
        log "launched scanner directly (PID $!)"
    fi
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_SECS}s"

if [ "$age" -lt "$STALE_SECS" ]; then
    log "scanner healthy — nothing to do"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_SECS}s) — restarting"

pid=$(_scanner_pid)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "killing wedged scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    sleep 2
fi

# Remove stale lock so the restarted process can acquire it.
rm -f "$LOCK_FILE"

_restart_scanner
