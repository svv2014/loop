#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat is stale.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# On each run it reads the scanner-heartbeat file written by scanner.sh
# every tick. If the file is older than STALE_THRESHOLD_SECONDS (default 15
# min = 2× the default 5-min poll interval with margin), the watchdog kills
# the scanner PID and, on macOS, triggers launchd to restart it; on Linux it
# removes the stale lock file so the next cron invocation starts cleanly.
#
# Flags:
#   --dry-run   report what would happen without killing/restarting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_THRESHOLD_SECONDS="${LOOP_SCANNER_WATCHDOG_STALE:-900}"  # 15 min
SCANNER_LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
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

# _file_age_seconds <path> — prints the age of the file in seconds.
# Portable: tries macOS stat -f%m first, then GNU stat -c%Y.
_file_age_seconds() {
    local path="$1"
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

log "tick (stale-threshold=${STALE_THRESHOLD_SECONDS}s dry-run=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found — scanner may not have started yet or LOOP_LOG_DIR is wrong"
    exit 0
fi

heartbeat_age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age: ${heartbeat_age}s (threshold=${STALE_THRESHOLD_SECONDS}s)"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD_SECONDS" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner heartbeat is stale (${heartbeat_age}s > ${STALE_THRESHOLD_SECONDS}s) — restarting"

# Kill the scanner if its PID is known and still alive.
if [ -f "$SCANNER_LOCK_FILE" ]; then
    local_pid=$(cat "$SCANNER_LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        if $DRY_RUN; then
            log "DRY-RUN: would kill scanner PID $local_pid"
        else
            log "killing wedged scanner PID $local_pid"
            kill "$local_pid" 2>/dev/null || true
            sleep 2
        fi
    fi
    if ! $DRY_RUN; then
        rm -f "$SCANNER_LOCK_FILE" 2>/dev/null || true
    fi
fi

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# macOS: launchd manages scanner lifecycle via KeepAlive. Removing the lock
# file and sending kickstart is sufficient; launchd will relaunch the process.
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list com.user.loop-scanner >/dev/null 2>&1; then
        log "kickstarting com.user.loop-scanner via launchd"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl stop com.user.loop-scanner 2>/dev/null || true
    else
        log "launchctl: com.user.loop-scanner not registered — scanner will self-start via cron or manual launch"
    fi
else
    # Linux/cron: lock file is already removed; the next cron tick starts a fresh scanner.
    log "non-macOS: stale lock removed — next cron invocation will start a fresh scanner"
fi

log "restart triggered"
