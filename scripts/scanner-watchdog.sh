#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat has gone stale.
#
# Designed to run every 5 min via launchd (StartInterval=300) or cron (*/5).
# The scanner writes ${LOOP_LOG_DIR}/scanner-heartbeat on every tick. If that
# file has not been updated within 2 × LOOP_SCANNER_INTERVAL seconds the
# scanner is considered wedged: the script kills it and launchd KeepAlive (or
# the next cron run) restarts it within one poll cycle.
#
# Flags:
#   --dry-run   report stale/ok status without killing the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
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
    log "no heartbeat file yet — scanner may not have started"
    exit 0
fi

hb_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
now=$(date +%s)
age=$(( now - hb_mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — restarting scanner"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner; exiting"
    exit 0
fi

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file found — scanner may have already exited; launchd will restart it"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$pid" ]; then
    log "lock file empty — scanner may have already exited"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID $pid is not alive — launchd will restart it"
    exit 0
fi

log "killing wedged scanner PID $pid"
kill "$pid" || log "WARN: kill $pid failed (already gone?)"
