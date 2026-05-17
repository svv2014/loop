#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file goes stale.
#
# Designed to run every 5 min via launchd (macOS) or cron (Linux).
# If the heartbeat file is older than LOOP_WATCHDOG_STALE_SECONDS (default
# 2 × LOOP_SCANNER_INTERVAL = 10 min), the scanner PID is killed so launchd
# (KeepAlive) or cron restarts it within one tick.
#
# macOS restart path: launchctl kickstart -k gui/$(id -u) com.user.loop-scanner
# Linux restart path: kill <scanner PID from lock file>; cron respawns at next tick
#
# Flags:
#   --dry-run   report stale status; do not kill or restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_SECONDS="${LOOP_WATCHDOG_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# Returns 0 (stale) if the heartbeat file is older than STALE_SECONDS,
# or if it does not exist.
_heartbeat_is_stale() {
    [ -f "$HEARTBEAT_FILE" ] || return 0
    local mtime now age
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))
    [ "$age" -ge "$STALE_SECONDS" ]
}

# _restart_scanner — kill the scanner PID so the OS supervisor restarts it.
# On macOS with launchd we also call kickstart to make the restart immediate
# rather than waiting for launchd's ThrottleInterval.
_restart_scanner() {
    local pid=""
    if [ -f "$LOCK_FILE" ]; then
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give the process a moment to clean up before kickstart.
        sleep 2
    else
        log "no live scanner PID found (lock=${LOCK_FILE})"
    fi

    # macOS: launchctl kickstart schedules an immediate restart via KeepAlive.
    if command -v launchctl >/dev/null 2>&1; then
        local uid
        uid=$(id -u)
        if launchctl list com.user.loop-scanner >/dev/null 2>&1; then
            log "launchctl kickstart gui/${uid}/com.user.loop-scanner"
            launchctl kickstart -k "gui/${uid}/com.user.loop-scanner" 2>/dev/null \
                || log "WARN: launchctl kickstart failed — launchd will auto-restart via KeepAlive"
        fi
    fi
    # Linux: cron will re-invoke scanner.sh --once at the next */5 tick; no
    # additional action needed beyond killing the PID above.
}

watchdog_run() {
    log "check (stale_threshold=${STALE_SECONDS}s)"

    if ! _heartbeat_is_stale; then
        log "ok — heartbeat is fresh"
        return 0
    fi

    log "STALE — heartbeat older than ${STALE_SECONDS}s (file=${HEARTBEAT_FILE})"

    if $DRY_RUN; then
        log "DRY-RUN: would restart scanner"
        return 0
    fi

    _restart_scanner
    log "restart triggered"
}

watchdog_run
