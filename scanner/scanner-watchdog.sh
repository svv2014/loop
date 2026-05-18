#!/usr/bin/env bash
# scanner-watchdog.sh — restart the Loop scanner if its heartbeat goes stale.
#
# Runs every 5 minutes via launchd (macOS) or cron (Linux).
# Checks ${LOOP_LOG_DIR}/scanner-heartbeat mtime; if older than
# LOOP_SCANNER_WATCHDOG_STALE_SECONDS (default: 2 × poll interval = 600s)
# the scanner process is killed so launchd/cron can restart it.
#
# Usage:
#   scanner-watchdog.sh            # normal run
#   scanner-watchdog.sh --dry-run  # report stale state without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"

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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE"; }

_file_age_seconds() {
    local f="$1"
    [ -f "$f" ] || { echo "999999"; return; }
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

_scanner_pid() {
    local pid=""
    [ -f "$LOCK_FILE" ] && pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    printf '%s' "$pid"
}

_kill_scanner() {
    local pid
    pid=$(_scanner_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        return 0
    fi
    # No live PID — remove stale lock so the next scanner start isn't blocked.
    if [ -f "$LOCK_FILE" ]; then
        log "removing stale lock $LOCK_FILE (no live PID)"
        rm -f "$LOCK_FILE"
    fi
    return 0
}

_restart_scanner_linux() {
    # On Linux the scanner runs via cron (--once). Killing any stuck continuous
    # instance clears the way; cron fires a fresh --once invocation within 5 min.
    pkill -f "scanner/scanner.sh" 2>/dev/null || true
    log "killed any running scanner.sh processes (cron will restart)"
}

_restart_scanner_macos() {
    # On macOS launchd keeps the scanner alive — kill the PID and launchd
    # restarts it automatically within ThrottleInterval seconds.
    _kill_scanner
    log "scanner killed; launchd KeepAlive will restart it"
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat ok (age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE heartbeat detected (age=${age}s threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner (not killing)"
    exit 0
fi

if [ "$(uname -s)" = "Darwin" ]; then
    _restart_scanner_macos
else
    _restart_scanner_linux
fi
