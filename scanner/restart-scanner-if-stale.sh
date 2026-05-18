#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads the scanner heartbeat file written by scanner.sh on every tick.
# If the heartbeat is older than STALE_THRESHOLD_SECONDS (default: 2 × poll
# interval = 600s), the scanner is considered wedged and is killed so that
# launchd (KeepAlive) or cron restarts it.
#
# Run every 5 minutes via launchd StartInterval or cron */5.
#
# Flags:
#   --dry-run   report staleness without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

# Resolve the scanner PID from the lock file.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 1
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

# mtime of a file in epoch seconds, portable across macOS/Linux.
_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent ($HEARTBEAT_FILE) — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
last_beat=$(_mtime "$HEARTBEAT_FILE")
age=$(( now - last_beat ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${age}s exceeds threshold=${STALE_THRESHOLD}s"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let launchd/cron restart it"
    exit 0
fi

pid=$(_scanner_pid || true)
if [ -n "$pid" ]; then
    log "killing wedged scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    # Remove the lock so a cron-based restart can acquire it immediately.
    rm -f "$LOCK_FILE"
    log "scanner killed; launchd/cron will restart it"
else
    log "WARN: scanner not running (no live PID in $LOCK_FILE) — nothing to kill"
    # Clean up a stale heartbeat so next watchdog tick starts fresh.
    rm -f "$HEARTBEAT_FILE"
fi
