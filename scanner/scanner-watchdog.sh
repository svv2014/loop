#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat is stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file's mtime is older than 2 × LOOP_SCANNER_INTERVAL (default 10 min),
# the scanner is considered silently wedged: its PID is killed and the lock file
# is removed so launchd (macOS) or cron (Linux) can restart a fresh instance.
#
# Designed to run every 5 min via launchd StartInterval or cron */5.
#
# Usage:
#   scanner-watchdog.sh            # check and restart if stale
#   scanner-watchdog.sh --dry-run  # report status without killing
#   scanner-watchdog.sh --help

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
    log "no heartbeat file at $HEARTBEAT_FILE — scanner may not have started yet"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -le "$STALE_THRESHOLD" ]; then
    log "heartbeat OK (age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE heartbeat detected: age=${age}s > ${STALE_THRESHOLD}s"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and remove lock — skipping"
    exit 0
fi

if [ -f "$LOCK_FILE" ]; then
    local_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        log "killing wedged scanner PID $local_pid"
        kill "$local_pid" 2>/dev/null || true
        sleep 2
    else
        log "lock file present but PID '${local_pid:-empty}' not alive"
    fi
    rm -f "$LOCK_FILE" 2>/dev/null || true
    log "lock file removed — launchd/cron will restart scanner"
else
    log "no lock file found; scanner may have already exited"
fi
