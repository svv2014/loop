#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner when its heartbeat goes stale.
#
# Fired by launchd (StartInterval 300) or cron (*/5 * * * *).
# If the scanner's heartbeat file hasn't been touched in 2 * POLL_INTERVAL
# seconds, kill the scanner PID so launchd KeepAlive=true can restart it.
# On Linux (cron mode) the scanner is started directly if no lock PID is alive.
#
# Usage: scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# No heartbeat file yet — scanner may not have completed its first tick.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file yet — waiting for first scanner tick"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat ok (age=${age}s, threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s) — restarting scanner"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and remove heartbeat"
    exit 0
fi

# Kill the scanner PID from the lock file; launchd KeepAlive restarts it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" || true
    else
        log "lock PID ${pid:-unknown} not alive — scanner may already be restarting"
        rm -f "$LOCK_FILE"
    fi
fi

# Remove the stale heartbeat so the next watchdog check doesn't fire again
# before the restarted scanner writes its first fresh heartbeat.
rm -f "$HEARTBEAT_FILE"

# Linux fallback: if running under cron (not launchd), restart scanner inline
# since there is no KeepAlive daemon manager.
if [ "$(uname -s)" != "Darwin" ]; then
    log "Linux: launching scanner (once) inline"
    nohup "$LOOP_ROOT/scanner/scanner.sh" --once \
        >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
fi
