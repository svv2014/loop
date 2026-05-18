#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Checks the scanner-heartbeat file written by scanner.sh on every tick.
# If the heartbeat is older than STALE_THRESHOLD_SECONDS (default: 2× poll interval,
# i.e. 600s) the scanner is considered wedged and is restarted:
#   - macOS: via launchctl kickstart (preferred) or kill-then-KeepAlive restart
#   - Linux: via pkill + cron-based auto-restart (cron must be configured)
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]
#
# Designed to run every 5 minutes via launchd (StartInterval=300) or cron.
# See templates/launchd/com.user.loop-scanner-watchdog.plist.template

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

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

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
SCANNER_LABEL="com.user.loop-scanner"

# _heartbeat_age — print seconds since heartbeat file was last modified.
# Returns 1 if the file does not exist.
_heartbeat_age() {
    [ -f "$HEARTBEAT_FILE" ] || return 1
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _restart_scanner — attempt to restart the scanner.
# macOS: launchctl kickstart; Linux: send SIGTERM to the old process (cron
# or systemd KeepAlive will bring a new one up).
_restart_scanner() {
    if $DRY_RUN; then
        log "DRY-RUN: would restart scanner"
        return 0
    fi
    if command -v launchctl >/dev/null 2>&1; then
        local domain
        domain="gui/$(id -u)"
        log "restarting via launchctl kickstart ${domain}/${SCANNER_LABEL}"
        if launchctl kickstart -k "${domain}/${SCANNER_LABEL}" 2>/dev/null; then
            return 0
        fi
        # Fallback: kill the PID (launchd KeepAlive will restart it).
        log "kickstart failed — falling back to kill-based restart"
    fi
    local lock_file="/tmp/loop-scanner.lock"
    if [ -f "$lock_file" ]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "sending SIGTERM to scanner PID $pid"
            kill "$pid" 2>/dev/null || true
            return 0
        fi
    fi
    log "WARN: no running scanner found to restart"
}

age=0
if ! age=$(_heartbeat_age); then
    log "heartbeat file missing ($HEARTBEAT_FILE) — scanner may not have started yet; skipping"
    exit 0
fi

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy (age=${age}s < threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s >= ${STALE_THRESHOLD}s) — restarting"
_restart_scanner
