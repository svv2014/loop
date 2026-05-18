#!/usr/bin/env bash
# scanner-watchdog.sh — detect a wedged scanner and restart it.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file's mtime is older than
# LOOP_WATCHDOG_STALE_THRESHOLD seconds (default: 2 × LOOP_SCANNER_INTERVAL),
# the scanner is considered wedged: the watchdog kills it and triggers a restart.
#
# Restart strategy (in order of preference):
#   macOS  — launchctl kickstart gui/$(id -u)/com.user.loop-scanner
#   Linux  — kill stale PID; scanner.sh will be restarted by cron or systemd
#
# Designed to run every 5 minutes:
#   macOS: launchd StartInterval 300
#          (see templates/launchd/com.user.loop-scanner-watchdog.plist.template)
#   Linux: */5 * * * * /path/to/scanner/scanner-watchdog.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
WATCHDOG_LOG="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
SCANNER_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$WATCHDOG_LOG"; }

# _heartbeat_age — return the age of the heartbeat file in seconds,
# or a large number if the file is missing.
_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 999999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — read PID from the heartbeat file (written by scanner.sh).
_scanner_pid() {
    [ -f "$HEARTBEAT_FILE" ] || return 1
    local pid
    pid=$(grep -o 'pid=[0-9]*' "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || true)
    [ -n "$pid" ] && echo "$pid"
}

# _kill_scanner — kill the scanner PID if it's still alive.
_kill_scanner() {
    local pid
    pid=$(_scanner_pid 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill -TERM "$pid" 2>/dev/null || true
        # Give it 5s to exit gracefully, then SIGKILL.
        local _n
        for _n in 1 2 3 4 5; do
            sleep 1
            kill -0 "$pid" 2>/dev/null || return 0
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

# _restart_scanner — restart scanner via launchctl (macOS) or nohup (Linux fallback).
_restart_scanner() {
    if command -v launchctl >/dev/null 2>&1; then
        local uid
        uid=$(id -u)
        log "restarting via launchctl kickstart gui/${uid}/${SCANNER_LABEL}"
        launchctl kickstart -k "gui/${uid}/${SCANNER_LABEL}" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — scanner may need manual restart"
    else
        log "launchctl not available — starting scanner directly"
        nohup "$LOOP_ROOT/scanner/scanner.sh" \
            >> "$LOOP_LOG_DIR/loop-scanner.log" 2>&1 &
        log "scanner restarted with PID $!"
    fi
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive — no action needed"
    exit 0
fi

log "ALERT: scanner heartbeat is stale (${age}s > ${STALE_THRESHOLD}s) — restarting"
_kill_scanner
_restart_scanner
