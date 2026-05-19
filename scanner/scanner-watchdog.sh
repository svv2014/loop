#!/usr/bin/env bash
# scanner-watchdog.sh — detect and recover a silently-wedged scanner.
#
# Checks the scanner-heartbeat file written by scanner.sh on every tick.
# If the heartbeat is older than LOOP_SCANNER_WATCHDOG_STALE_SECONDS (default:
# 2 × LOOP_SCANNER_INTERVAL = 600s), the scanner is considered wedged:
# its PID is killed so that launchd (KeepAlive=true) or cron auto-restarts it.
#
# Designed to run every 5 min via launchd StartInterval / cron */5.
# Safe to run even when the scanner is healthy — it exits 0 immediately.
#
# Flags:
#   --dry-run   report stale/ok status but do not kill the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
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
    log "heartbeat file absent — scanner has not run yet or LOOP_LOG_DIR is wrong"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "OK: heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: scanner heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s) — scanner may be wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let launchd/cron restart it"
    exit 0
fi

if [ ! -f "$LOCK_FILE" ]; then
    log "lock file $LOCK_FILE not found — scanner not holding a lock; launchd should restart it"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
if [ -z "$pid" ]; then
    log "lock file is empty — cannot determine scanner PID"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid is already dead — launchd/cron should restart it soon"
    exit 0
fi

log "killing wedged scanner PID $pid"
kill "$pid" 2>/dev/null || true
log "scanner PID $pid killed — launchd (KeepAlive) or cron will restart it"
