#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat written by scanner.sh every tick.
# If the file is missing or older than STALE_THRESHOLD_SECONDS (default:
# 2 × LOOP_SCANNER_INTERVAL, min 600s), the scanner is considered wedged:
#   - macOS: launchctl kickstart forces launchd to restart the scanner service.
#   - Linux: kill the PID from the heartbeat file; the cron entry spawns a new one.
#
# Designed to run every 5 minutes via launchd StartInterval or cron */5.
#
# Flags:
#   --dry-run   report stale/fresh status without taking action
#   --once      single check (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
# Ensure a floor of 600s so a brief scan delay doesn't trigger a spurious restart.
if [ "$STALE_THRESHOLD" -lt 600 ] 2>/dev/null; then
    STALE_THRESHOLD=600
fi

DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"

_heartbeat_age() {
    [ -f "$HEARTBEAT_FILE" ] || { echo "999999"; return; }
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

_scanner_pid_from_heartbeat() {
    [ -f "$HEARTBEAT_FILE" ] || return 1
    awk '{print $1; exit}' "$HEARTBEAT_FILE" 2>/dev/null
}

_kill_scanner() {
    local pid
    pid=$(_scanner_pid_from_heartbeat 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
    fi
}

_restart_scanner() {
    local os
    os=$(uname -s)
    if [ "$os" = "Darwin" ]; then
        local service_label="com.user.loop-scanner"
        if launchctl list "$service_label" >/dev/null 2>&1; then
            log "kickstarting $service_label via launchctl"
            launchctl kickstart -k "gui/$(id -u)/$service_label" 2>/dev/null \
                || launchctl stop "$service_label" 2>/dev/null || true
        else
            log "WARN: $service_label not found in launchctl — scanner may not be managed by launchd"
        fi
    else
        # Linux: kill the old PID; cron will spawn a new scanner on the next tick.
        _kill_scanner
        log "killed stale scanner (cron will respawn)"
    fi
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -ge "$STALE_THRESHOLD" ]; then
    if $DRY_RUN; then
        log "DRY-RUN: scanner heartbeat stale (${age}s >= ${STALE_THRESHOLD}s) — would restart"
    else
        log "scanner heartbeat stale (${age}s >= ${STALE_THRESHOLD}s) — restarting"
        _kill_scanner
        _restart_scanner
    fi
else
    log "scanner heartbeat fresh (${age}s < ${STALE_THRESHOLD}s) — ok"
fi
