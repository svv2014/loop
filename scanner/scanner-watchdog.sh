#!/usr/bin/env bash
# scanner-watchdog.sh — Detect and restart a silently-wedged scanner process.
#
# The scanner can become wedged: PID alive, sleep loop intact, but no events
# emitted for hours. This script checks the scanner-heartbeat file written at
# the top of every scan tick. If the heartbeat is older than
# LOOP_WATCHDOG_STALE_THRESHOLD seconds (default: 2 × LOOP_SCANNER_INTERVAL),
# the scanner process is killed so launchd / cron can restart it.
#
# Designed to run every 5 min via launchd (StartInterval 300) or cron.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Default stale threshold: 2 × poll interval, minimum 120 s.
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

# _heartbeat_age — print seconds since the heartbeat file was last written,
# or a large value (9999999) when the file is absent so the caller treats a
# missing heartbeat as stale.
_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 9999999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
            || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
            || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — read the PID from the lock file; print nothing if absent/dead.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 0
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null && echo "$pid" || true
}

main() {
    local age
    age=$(_heartbeat_age)

    if [ "$age" -lt "$STALE_THRESHOLD" ]; then
        log "OK: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
        return 0
    fi

    log "STALE: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s"

    local pid
    pid=$(_scanner_pid)

    if [ -z "$pid" ]; then
        log "scanner PID not found — launchd/cron will restart it on next interval"
        return 0
    fi

    if $DRY_RUN; then
        log "DRY-RUN: would kill scanner PID $pid"
        return 0
    fi

    log "killing stale scanner PID $pid — expect launchd/cron restart"
    kill "$pid" 2>/dev/null || log "WARN: kill $pid failed (already gone?)"
}

main
