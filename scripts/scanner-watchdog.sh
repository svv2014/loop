#!/usr/bin/env bash
# scanner-watchdog.sh — kill a wedged scanner so launchd/cron can restart it.
#
# Reads the mtime of ${LOOP_LOG_DIR}/scanner-heartbeat. If it is older than
# LOOP_SCANNER_WATCHDOG_THRESHOLD seconds (default: 2 × LOOP_SCANNER_INTERVAL,
# i.e. 600 s), the scanner is considered wedged and is sent SIGTERM so that
# launchd (KeepAlive=true) restarts it automatically.
#
# Designed to run every 5 min via launchd/cron. Linux cron example:
#   */5 * * * * /path/to/loop/scripts/scanner-watchdog.sh
#
# Flags:
#   --dry-run   report staleness without killing the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

log "check (threshold=${THRESHOLD}s dry-run=${DRY_RUN})"

# Heartbeat file absent means the scanner has not yet completed a first tick —
# give it one full threshold window before acting.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may still be starting; no action"
    exit 0
fi

heartbeat_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
now=$(date +%s)
age=$(( now - heartbeat_mtime ))

if [ "$age" -lt "$THRESHOLD" ]; then
    log "ok (heartbeat age=${age}s < ${THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= ${THRESHOLD}s — scanner appears wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "lock file absent — scanner not running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
if [ -z "$scanner_pid" ]; then
    log "WARN: lock file empty — cannot determine scanner PID"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is not alive — launchd will restart it"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $scanner_pid"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid (launchd/cron will restart)"
kill "$scanner_pid" || log "WARN: kill $scanner_pid failed (already gone?)"
