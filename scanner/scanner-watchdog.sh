#!/usr/bin/env bash
# scanner-watchdog.sh — restart a silently-wedged scanner process.
#
# Reads the heartbeat file written by scanner.sh on every tick. If the file is
# older than LOOP_WATCHDOG_STALE_SECONDS (default: 2 × poll interval = 600s),
# the scanner is considered wedged: kill its PID so launchd / the cron wrapper
# can restart it. On Linux (cron mode) the script simply exits after the kill;
# the next cron firing of scanner.sh --once will start a fresh run.
#
# Usage:
#   scanner-watchdog.sh           # normal mode: kill stale scanner and exit
#   scanner-watchdog.sh --dry-run # print diagnosis, no kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
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
    log "no heartbeat file at $HEARTBEAT_FILE — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat ok (age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat age=${age}s exceeds threshold=${STALE_THRESHOLD}s — scanner appears wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file at $LOCK_FILE — scanner not running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file empty — nothing to kill"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid already dead — lock is stale; launchd will restart"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $scanner_pid"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid (SIGTERM)"
kill "$scanner_pid" 2>/dev/null || true
sleep 2
if kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid still alive after SIGTERM — sending SIGKILL"
    kill -9 "$scanner_pid" 2>/dev/null || true
fi
log "done — launchd (KeepAlive=true) will restart the scanner"
