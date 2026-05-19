#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it has not emitted a heartbeat tick recently.
#
# The scanner writes ${LOOP_LOG_DIR}/scanner-heartbeat on every tick. This script
# checks that file's mtime; if it is older than STALE_THRESHOLD seconds the scanner
# is considered silently wedged and is restarted via launchctl (macOS) or a direct
# kill + re-exec (Linux/fallback).
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# No-ops when --dry-run is passed; only logs what it would do.
#
# Usage:
#   scanner-watchdog.sh          # check and restart if stale
#   scanner-watchdog.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Restart if heartbeat is older than 2× poll interval (default 10 min).
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="/tmp/loop-scanner.lock"
HB_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _mtime <file> — print the file's modification time as a Unix timestamp.
_mtime() {
    stat -f%m "$1" 2>/dev/null \
        || stat -c%Y "$1" 2>/dev/null \
        || echo 0
}

log "check (threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

# If the heartbeat file does not exist yet the scanner may not have completed
# its first tick; give it one full poll interval before alarming.
if [ ! -f "$HB_FILE" ]; then
    log "heartbeat file absent — scanner may be starting up; skipping restart"
    exit 0
fi

age=$(( $(date +%s) - $(_mtime "$HB_FILE") ))
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# Kill existing scanner process (if any) so launchd/cron can restart it.
if [ -f "$LOCK_FILE" ]; then
    local_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        log "killing stale scanner PID $local_pid"
        kill "$local_pid" 2>/dev/null || true
        sleep 2
    fi
    rm -f "$LOCK_FILE" 2>/dev/null || true
fi

# On macOS, ask launchd to restart the service (respects KeepAlive).
if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "launchd kickstart sent"
    else
        log "launchd kickstart failed — launchd will auto-restart via KeepAlive"
    fi
else
    # Linux: removing the lock file is enough; cron will start a new instance
    # on the next 5-minute tick. Log the gap so operators can investigate.
    log "lock removed — cron will restart scanner on next tick"
fi
