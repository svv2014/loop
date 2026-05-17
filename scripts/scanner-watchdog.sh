#!/usr/bin/env bash
# scanner-watchdog.sh — restart the Loop scanner if it stops writing heartbeats.
#
# Checks ${LOOP_LOG_DIR}/scanner-heartbeat mtime. If it is older than
# LOOP_SCANNER_STALE_SECONDS (default: 2 × LOOP_SCANNER_INTERVAL = 600 s),
# the scanner is considered wedged and is killed so launchd / cron restarts it.
#
# Designed to run every 5 min via launchd (StartInterval 300) or cron (*/5).
#
# Flags:
#   --dry-run   report stale status without killing the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"

DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# Portable mtime: macOS stat -f%m vs GNU stat -c%Y
_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0
}

log "check (threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file yet — scanner may not have started"
    exit 0
fi

now=$(date +%s)
mtime=$(_mtime "$HEARTBEAT_FILE")
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok (heartbeat age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat age=${age}s > ${STALE_THRESHOLD}s — scanner appears wedged"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${scanner_pid:-unknown}"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    log "scanner killed — launchd/cron will restart"
else
    log "WARN: no live scanner PID found (pid=${scanner_pid:-none}) — launchd/cron should restart automatically"
fi
