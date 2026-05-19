#!/usr/bin/env bash
# scanner-watchdog.sh — Liveness watchdog for the Loop scanner.
#
# Reads the scanner heartbeat file written by scanner.sh on every tick.
# If the heartbeat is older than the stale threshold, the scanner is
# considered wedged and is killed so launchd (KeepAlive) restarts it.
#
# Designed to run every 5 min via launchd (StartInterval 300) or cron.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]
#
# Configuration (via loop.env or environment):
#   LOOP_SCANNER_INTERVAL        poll cadence in seconds (default 300)
#   LOOP_WATCHDOG_STALE_FACTOR   multiplier applied to LOOP_SCANNER_INTERVAL
#                                to derive the stale threshold (default 2,
#                                so stale = 2 × interval = 10 min at defaults)

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

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_FACTOR="${LOOP_WATCHDOG_STALE_FACTOR:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_FACTOR ))
HB_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log "check: heartbeat=${HB_FILE} stale_threshold=${STALE_THRESHOLD}s"

if [ ! -f "$HB_FILE" ]; then
    log "INFO: no heartbeat file yet — scanner may not have completed its first tick"
    exit 0
fi

# Portable mtime: try macOS stat first, fall back to GNU stat.
hb_mtime=$(stat -f%m "$HB_FILE" 2>/dev/null || stat -c%Y "$HB_FILE" 2>/dev/null || echo 0)
now=$(date +%s)
age=$(( now - hb_mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: scanner is live"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — attempting restart"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let launchd restart it"
    exit 0
fi

# Find scanner PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing stale scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    # Give launchd a moment to observe the exit before we log completion.
    sleep 2
    log "scanner PID $scanner_pid terminated — launchd (KeepAlive) will restart it"
else
    log "scanner lock PID '${scanner_pid}' not found or not alive — launchd will restart on its own"
    # Remove a stale lock file so the next scanner invocation can acquire it.
    rm -f "$LOCK_FILE"
fi
