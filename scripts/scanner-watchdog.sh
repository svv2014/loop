#!/usr/bin/env bash
# scanner-watchdog.sh — Restart the scanner if its heartbeat goes stale.
#
# Run every 5 min via launchd (StartInterval=300) or cron (*/5).
# If scanner-heartbeat mtime exceeds 2 * POLL_INTERVAL, kills the scanner
# PID from the lock file so launchd (KeepAlive) or cron restarts it.
#
# Usage: scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

DRY_RUN=false
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown flag: $_arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

_file_age_seconds() {
    local f="$1"
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found — scanner may not have ticked yet"
    exit 0
fi

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: scanner is alive"
    exit 0
fi

log "STALE: heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s) — restarting scanner"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# Kill by PID from lock file (graceful SIGTERM so the lock trap fires).
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    else
        log "lock file present but PID ${pid:-?} not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
fi

# On macOS, kick launchd immediately rather than waiting for ThrottleInterval.
if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "launchd kickstart: com.user.loop-scanner restarted"
    else
        log "launchctl kickstart failed — scanner will restart via KeepAlive"
    fi
else
    log "Linux: scanner will restart on the next cron tick (~5 min)"
fi
