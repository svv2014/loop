#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file is stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file's mtime is older than STALE_THRESHOLD_SECONDS (default: 2 * poll
# interval = 600s), the scanner is considered wedged and is killed so launchd
# (or cron) can restart it.
#
# Design:
#   - macOS: run as a launchd StartInterval job every 300s.
#   - Linux: add a crontab entry: */5 * * * *
#   - Uses the scanner lock file (/tmp/loop-scanner.lock) to get the PID.
#   - On no heartbeat file (scanner never ran): no action (avoids race on startup).
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

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
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file yet — scanner may not have started; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s — scanner healthy"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — scanner appears wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file found at $LOCK_FILE — scanner not running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file empty — cannot kill scanner"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already dead — lock file is stale; launchd will restart"
    rm -f "$LOCK_FILE" 2>/dev/null || true
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $scanner_pid"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid — launchd/cron will restart"
kill -TERM "$scanner_pid" 2>/dev/null || kill -KILL "$scanner_pid" 2>/dev/null || true
log "done"
