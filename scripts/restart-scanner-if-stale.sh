#!/usr/bin/env bash
# restart-scanner-if-stale.sh — liveness watchdog for the Loop scanner.
#
# Reads the scanner-heartbeat file written by scanner.sh on every tick.
# If the file is absent or older than STALE_THRESHOLD seconds, the scanner
# is considered wedged and is force-restarted.
#
# macOS: uses launchctl kickstart to let launchd own the restart.
# Linux: kills the PID from /tmp/loop-scanner.lock; cron respawns scanner.
#
# Run every 5 min via launchd (macOS) or cron (Linux).
# STALE_THRESHOLD defaults to 2 × LOOP_SCANNER_INTERVAL (600s for the
# default 5-min poll cadence). Override with LOOP_SCANNER_STALE_THRESHOLD.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age_seconds <path>
# Prints seconds since the file was last modified, or 999999 if missing.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy — no action"
    exit 0
fi

log "WARN: scanner appears wedged (heartbeat ${age}s old) — forcing restart"

# Kill the scanner process if we can identify it via the lock file.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
fi

# Restart via launchd (macOS) or rely on cron/external supervisor (Linux).
if command -v launchctl >/dev/null 2>&1; then
    uid=$(id -u)
    if launchctl kickstart -k "gui/${uid}/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart succeeded"
    else
        log "WARN: launchctl kickstart failed — launchd will auto-restart via KeepAlive"
    fi
else
    log "Linux: scanner PID killed; cron will respawn on next */5 tick"
fi
