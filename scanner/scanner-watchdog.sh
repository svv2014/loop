#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops writing its heartbeat.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is absent or its mtime
# is older than STALE_THRESHOLD_SECONDS (default: 2 × poll interval = 600s),
# the scanner is considered wedged.  The watchdog kills the PID stored in
# /tmp/loop-scanner.lock and relies on launchd (macOS) or cron (Linux) to
# restart the scanner binary.  On macOS it additionally calls
# `launchctl kickstart` if LOOP_LAUNCHD_LABEL is set.
#
# Usage:
#   scanner-watchdog.sh            # single check (default; run from launchd / cron)
#   scanner-watchdog.sh --dry-run  # report state without restarting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE:-$(( POLL_INTERVAL * 2 ))}"
LAUNCHD_LABEL="${LOOP_LAUNCHD_LABEL:-}"

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

# _heartbeat_age_seconds — return seconds since heartbeat was written, or
# a very large number if the file is absent (treat as maximally stale).
_heartbeat_age_seconds() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y  "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age_seconds)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action needed"
    exit 0
fi

log "STALE: scanner heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner (PID from $LOCK_FILE)"
    exit 0
fi

# Kill the scanner PID so launchd/cron restarts the binary.
pid=""
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "killing stale scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    # Give it a moment to exit and release the lock; if it doesn't, SIGKILL.
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
else
    log "scanner PID '${pid}' not running — removing stale lock if present"
    rm -f "$LOCK_FILE"
fi

# On macOS, kickstart the launchd service so it restarts immediately rather
# than waiting for the next launchd check interval.
if [ -n "$LAUNCHD_LABEL" ] && command -v launchctl >/dev/null 2>&1; then
    log "kickstarting launchd service: $LAUNCHD_LABEL"
    launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null \
        || log "WARN: launchctl kickstart failed (non-fatal — launchd will auto-restart)"
fi

log "restart triggered"
