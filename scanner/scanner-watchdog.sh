#!/usr/bin/env bash
# scanner/scanner-watchdog.sh — Scanner liveness watchdog.
#
# Reads the heartbeat file written by scanner.sh on every tick.
# If the file is missing or older than LOOP_SCANNER_WATCHDOG_STALE_SECS (default: 900s),
# the scanner is considered wedged: its PID is killed so launchd (KeepAlive) or
# cron restarts it automatically.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
#
# Usage:
#   scanner-watchdog.sh           # normal operation
#   scanner-watchdog.sh --dry-run # report staleness, do not kill

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
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
# Stale threshold: 2 × default poll interval (300s), minimum 900s.
STALE_SECS="${LOOP_SCANNER_WATCHDOG_STALE_SECS:-900}"

# _file_age_secs <path>
# Prints the age of a file in seconds, or empty string on error.
_file_age_secs() {
    local path="$1"
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent: $HEARTBEAT_FILE — scanner may not have started yet; skipping"
    exit 0
fi

age=$(_file_age_secs "$HEARTBEAT_FILE" || echo "$STALE_SECS")

if [ "$age" -lt "$STALE_SECS" ]; then
    log "ok: heartbeat age=${age}s (threshold=${STALE_SECS}s)"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= ${STALE_SECS}s — scanner appears wedged"

if $DRY_RUN; then
    log "dry-run: would kill scanner and let launchd/cron restart it"
    exit 0
fi

# Read the scanner PID from the lock file. Kill it so launchd (KeepAlive=true)
# or cron restarts a fresh instance. Fall back to pkill if the lock is missing.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing scanner PID $pid"
        kill "$pid" || true
        # Remove stale heartbeat so the next watchdog run doesn't immediately re-kill.
        rm -f "$HEARTBEAT_FILE"
        log "done: scanner killed; launchd/cron will restart it"
        exit 0
    fi
    log "lock file exists but PID ${pid:-<empty>} is not alive — removing stale lock"
    rm -f "$LOCK_FILE"
fi

# No live PID found in lock. Use pkill as best-effort fallback.
if pkill -f "scanner/scanner.sh" 2>/dev/null; then
    rm -f "$HEARTBEAT_FILE"
    log "killed scanner via pkill; launchd/cron will restart it"
else
    log "no scanner process found to kill (may have already exited)"
fi
