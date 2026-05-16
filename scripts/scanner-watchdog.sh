#!/usr/bin/env bash
# scanner-watchdog.sh — detect a silently-wedged scanner and kill it so launchd restarts it.
#
# Runs every 5 minutes (via launchd StartInterval). Reads the heartbeat file written by
# scanner.sh on every tick. If the file is older than 2 × POLL_INTERVAL (default 10 min),
# the scanner is considered wedged and its PID is sent SIGTERM so launchd KeepAlive fires.
#
# Usage: called by launchd; can also be run manually for diagnostics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HEARTBEAT="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

# Portable mtime: try macOS stat first, fall back to GNU stat.
_mtime() { stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0; }

age=$(( $(date +%s) - $(_mtime "$HEARTBEAT") ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner heartbeat ok (age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s) — scanner appears wedged"

if [ -f "$SCANNER_LOCK" ]; then
    pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "sending SIGTERM to scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        log "done — launchd KeepAlive will restart the scanner"
    else
        log "lock file present but PID ${pid:-<empty>} is not alive — removing stale lock"
        rm -f "$SCANNER_LOCK"
    fi
else
    log "no scanner lock file found; scanner is not running — nothing to kill"
fi
