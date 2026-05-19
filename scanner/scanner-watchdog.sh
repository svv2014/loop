#!/usr/bin/env bash
# scanner-watchdog.sh — Restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file is absent or older than STALE_THRESHOLD_SECONDS, kills any running
# scanner and lets launchd / cron restart it.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
#
# Flags:
#   --dry-run  Print what would happen without taking action
#
# Env vars:
#   LOOP_SCANNER_INTERVAL   Scanner poll interval in seconds (default 300)
#   LOOP_WATCHDOG_MULTIPLIER  Stale = interval × multiplier (default 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
MULTIPLIER="${LOOP_WATCHDOG_MULTIPLIER:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * MULTIPLIER ))
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
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

now=$(date +%s)

# Determine heartbeat age.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    # No heartbeat file — scanner may never have run or was fully replaced.
    # Treat as infinitely stale only if the lock file is also old (scanner running but silent).
    if [ ! -f "$LOCK_FILE" ]; then
        log "heartbeat absent and no lock file — scanner is not running; skipping"
        exit 0
    fi
    heartbeat_age=$(( STALE_THRESHOLD + 1 ))
    log "heartbeat absent but lock file exists — treating age as stale (${heartbeat_age}s)"
else
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo 0)
    heartbeat_age=$(( now - mtime ))
    log "heartbeat age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s"
fi

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat stale (${heartbeat_age}s >= ${STALE_THRESHOLD}s threshold)"

# Identify scanner PID from lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    if $DRY_RUN; then
        log "DRY-RUN: would kill scanner PID $scanner_pid"
    else
        log "killing wedged scanner PID $scanner_pid"
        kill "$scanner_pid" 2>/dev/null || kill -9 "$scanner_pid" 2>/dev/null || true
        rm -f "$LOCK_FILE"
        log "scanner killed; launchd/cron will restart it"
    fi
else
    log "WARN: no live scanner PID found in lock file (lock=${LOCK_FILE})"
    if ! $DRY_RUN; then
        rm -f "$LOCK_FILE"
        log "stale lock removed; scanner will restart on next launchd/cron tick"
    fi
fi
