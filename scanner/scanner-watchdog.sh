#!/usr/bin/env bash
# scanner-watchdog.sh — detect a wedged scanner and restart it.
#
# The scanner writes ${LOOP_LOG_DIR}/scanner-heartbeat on every tick.
# This watchdog checks that file's mtime. If it hasn't been updated in
# 2 × POLL_INTERVAL seconds, the scanner is considered wedged: we kill
# the PID recorded in /tmp/loop-scanner.lock and let launchd (KeepAlive)
# or cron restart it automatically.
#
# Designed to run every 5 min via launchd (macOS) or cron (Linux).
# Safe to run concurrently with the scanner — it only acts when the
# heartbeat is provably stale.
#
# Usage:
#   scanner-watchdog.sh            # check once, exit
#   scanner-watchdog.sh --dry-run  # report verdict without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
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

now=$(date +%s)

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file missing — scanner may not have started yet (${HEARTBEAT_FILE})"
    exit 0
fi

mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy (heartbeat ${age}s old)"
    exit 0
fi

log "STALE: heartbeat ${age}s old (>${STALE_THRESHOLD}s) — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID from $LOCK_FILE and let launchd/cron restart it"
    exit 0
fi

if [ ! -f "$LOCK_FILE" ]; then
    log "lock file missing — scanner not running, launchd/cron will restart it"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
if [ -z "$scanner_pid" ]; then
    log "WARN: lock file empty, removing it"
    rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid already dead — removing stale lock"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid — launchd/cron will restart it"
kill "$scanner_pid" 2>/dev/null || true

# Remove the lock file so launchd's restarted process can acquire it immediately
# rather than waiting to detect the stale PID on its own.
sleep 2
if [ -f "$LOCK_FILE" ]; then
    current_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ "$current_pid" = "$scanner_pid" ]; then
        rm -f "$LOCK_FILE"
        log "removed stale lock for PID $scanner_pid"
    fi
fi

log "restart triggered"
