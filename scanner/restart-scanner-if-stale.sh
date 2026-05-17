#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh at the start
# of every tick). If the file is older than LOOP_SCANNER_WATCHDOG_STALE_SECONDS
# (default 900 = 3× the default 300 s poll interval) AND a scanner PID is alive
# in the lock file (confirming a wedged rather than stopped process), kills the
# PID and, on macOS, issues a launchctl kickstart so KeepAlive fires immediately.
# On Linux, killing the PID is sufficient — cron re-launches the scanner within
# the next 5-minute slot.
#
# Designed to run every 5 min via launchd (StartInterval 300) or cron (*/5).
# Install via: ./install.sh --bootstrap  (adds the launchd plist / cron entry).
#
# Flags:
#   --dry-run   report stale status without killing or restarting
#   -h|--help   print this header

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_SECONDS="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-900}"
LOCK_FILE="/tmp/loop-scanner.lock"
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

# _file_age_seconds <path>
# Returns the number of seconds since the file was last modified.
# Supports both macOS (stat -f%m) and Linux (stat -c%Y).
_file_age_seconds() {
    local path="$1"
    local mtime
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - mtime ))
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file at $HEARTBEAT_FILE — scanner may not have started yet; skipping"
    exit 0
fi

age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$age" -lt "$STALE_SECONDS" ]; then
    log "heartbeat ok (age=${age}s < threshold=${STALE_SECONDS}s)"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= threshold=${STALE_SECONDS}s"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner (heartbeat stale)"
    exit 0
fi

# Kill the wedged scanner process so launchd/cron can restart it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
    else
        log "lock file present but PID ${pid:-unknown} is not alive — lock is already stale"
    fi
else
    log "no lock file found at $LOCK_FILE"
fi

# On macOS, kickstart immediately rather than waiting for the next KeepAlive cycle.
if command -v launchctl >/dev/null 2>&1; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart issued for com.user.loop-scanner"
    else
        log "launchctl kickstart failed or service not loaded — scanner will restart via KeepAlive"
    fi
fi

log "restart triggered"
