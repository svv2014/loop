#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Liveness watchdog for the Loop scanner.
#
# Fires every 5 min via launchd (macOS) or cron (Linux).
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat mtime; if the file is older than
# LOOP_SCANNER_STALE_THRESHOLD (default 600s = 2 × default poll_interval),
# kills the scanner process and lets launchd (KeepAlive=true) restart it.
#
# On Linux (no launchd), kills the scanner PID outright; cron re-launches it
# on the next 5-min tick.
#
# Usage: restart-scanner-if-stale.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-600}"
SCANNER_LOCK="/tmp/loop-scanner.lock"
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

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

_file_age_seconds() {
    local f="$1"
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy (heartbeat age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — restarting"

scanner_pid=""
if [ -f "$SCANNER_LOCK" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID=${scanner_pid:-unknown} and trigger restart"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "sending SIGTERM to stale scanner PID $scanner_pid"
    kill -TERM "$scanner_pid" 2>/dev/null || true
    sleep 3
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "scanner did not exit after SIGTERM — sending SIGKILL"
        kill -KILL "$scanner_pid" 2>/dev/null || true
    fi
fi
rm -f "$SCANNER_LOCK"

if command -v launchctl >/dev/null 2>&1; then
    log "restarting via launchctl kickstart"
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        || log "WARN: launchctl kickstart failed — launchd will restart scanner on next exit"
else
    log "no launchctl — cron will restart scanner on next 5-min tick"
fi
