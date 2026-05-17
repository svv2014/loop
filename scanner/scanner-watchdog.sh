#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops emitting heartbeats.
#
# Run every 5 minutes by launchd (macOS) or cron (Linux).
# If the scanner heartbeat file is older than 2×POLL_INTERVAL the scanner is
# considered wedged: we kill the PID in the lock file and let launchd/cron
# restart it via KeepAlive=true.
#
# Usage:
#   scanner-watchdog.sh           # normal run
#   scanner-watchdog.sh --dry-run # print verdict without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( 2 * POLL_INTERVAL ))

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

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file at $HEARTBEAT_FILE — scanner not yet started; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -le "$STALE_THRESHOLD" ]; then
    log "ok — scanner is alive"
    exit 0
fi

log "WARN: scanner heartbeat is stale (${age}s > ${STALE_THRESHOLD}s) — triggering restart"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID and let launchd restart it"
    exit 0
fi

# Kill the wedged scanner process so launchd/cron restarts it.
if [ -f "$LOCK_FILE" ]; then
    local_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        log "killing wedged scanner PID $local_pid"
        kill "$local_pid" 2>/dev/null || true
    else
        log "lock file present but PID ${local_pid:-<empty>} is not alive — cleaning up"
        rm -f "$LOCK_FILE"
    fi
fi

# On macOS with launchd: kickstart the service so it restarts immediately
# instead of waiting for the ThrottleInterval.
if command -v launchctl >/dev/null 2>&1; then
    local_label="gui/$(id -u)/com.user.loop-scanner"
    if launchctl print "$local_label" >/dev/null 2>&1; then
        log "kickstarting launchd service $local_label"
        launchctl kickstart -k "$local_label" 2>/dev/null || true
    fi
fi
