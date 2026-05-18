#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a wedged scanner process.
#
# Reads scanner-heartbeat mtime from $LOOP_LOG_DIR. If the file is older
# than STALE_THRESHOLD seconds the scanner is considered wedged: its PID
# (from the lock file) is killed so launchd (KeepAlive=true) auto-restarts it.
#
# STALE_THRESHOLD defaults to 2 × LOOP_SCANNER_INTERVAL (600s).
# A single missed tick does not trigger a restart; only sustained silence does.
#
# Run every ~5 minutes via launchd StartInterval=300 or cron */5.
#
# Usage:
#   scanner/scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
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

# Portable mtime reader (macOS stat vs GNU stat).
_file_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0
}

log "check (threshold=${STALE_THRESHOLD}s, dry-run=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet or LOOP_LOG_DIR is wrong"
    exit 0
fi

now=$(date +%s)
mtime=$(_file_mtime "$HEARTBEAT_FILE")
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "OK: heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — scanner appears wedged"

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file at $LOCK_FILE — scanner not running; launchd will restart it"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")

if [ -z "$scanner_pid" ]; then
    log "lock file empty — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already dead — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $scanner_pid"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid (launchd KeepAlive will restart it)"
kill "$scanner_pid" 2>/dev/null || true

# Give launchd a moment to clean up before the next watchdog tick.
sleep 2

log "done"
