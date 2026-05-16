#!/usr/bin/env bash
# scanner-watchdog.sh — Detect a wedged scanner and restart it.
#
# Runs every 5 minutes via launchd (macOS) or cron (Linux).
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat; if the file is older than
# 2 × LOOP_SCANNER_INTERVAL + 60 s (grace), the scanner is considered
# wedged and is restarted:
#   macOS: launchctl kickstart -k gui/<uid>/com.user.loop-scanner
#   Linux: kill the PID in /tmp/loop-scanner.lock (cron respawns it)
#
# Exits 0 in all cases — a non-zero exit from a launchd StartInterval job
# would suppress subsequent runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 + 60 ))
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0
}

heartbeat_age=$(( $(date +%s) - $(_mtime "$HEARTBEAT_FILE") ))

if [ "$heartbeat_age" -le "$STALE_THRESHOLD" ]; then
    log "scanner healthy (heartbeat_age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat is ${heartbeat_age}s old (threshold=${STALE_THRESHOLD}s) — restarting scanner"

if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart sent"
    else
        log "WARN: launchctl kickstart failed — scanner may need manual restart"
    fi
else
    if [ -f "$LOCK_FILE" ]; then
        local_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
            kill "$local_pid" 2>/dev/null && log "killed wedged scanner PID $local_pid — cron will restart"
        else
            rm -f "$LOCK_FILE"
            log "stale lock removed — scanner will restart on next cron tick"
        fi
    else
        log "WARN: no lock file found — scanner may not be running"
    fi
fi

exit 0
