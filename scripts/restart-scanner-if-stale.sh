#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads the heartbeat file written by scanner.sh on every tick.
# If the file is absent or older than STALE_THRESHOLD_SECONDS (default:
# 2 × poll interval = 600s), the scanner is considered wedged and is
# restarted:
#   - macOS (launchd): launchctl kickstart the scanner service.
#   - Linux (cron):    pkill the scanner process; cron re-invokes it next tick.
#
# Designed to run every 5 min via launchd (StartInterval 300) or cron.
#
# Flags:
#   --dry-run   log what would happen without taking action

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
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

_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "999999"
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

_restart_scanner_launchd() {
    local label="com.user.loop-scanner"
    log "restarting scanner via launchctl kickstart -k gui/$(id -u)/${label}"
    if $DRY_RUN; then
        log "DRY-RUN: would run: launchctl kickstart -k gui/$(id -u)/${label}"
        return
    fi
    launchctl kickstart -k "gui/$(id -u)/${label}" 2>/dev/null \
        || launchctl stop  "$label" 2>/dev/null \
        || true
}

_restart_scanner_linux() {
    log "restarting scanner via pkill (cron will re-invoke on next tick)"
    if $DRY_RUN; then
        log "DRY-RUN: would run: pkill -f scanner.sh"
        return
    fi
    pkill -f "scanner.sh" 2>/dev/null || true
}

main() {
    local age
    age=$(_heartbeat_age)
    log "scanner heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

    if [ "$age" -lt "$STALE_THRESHOLD" ]; then
        log "scanner is healthy — no action"
        return 0
    fi

    log "WARN: scanner appears wedged (heartbeat ${age}s old, threshold ${STALE_THRESHOLD}s) — restarting"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        _restart_scanner_launchd
    else
        _restart_scanner_linux
    fi
}

main
