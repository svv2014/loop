#!/usr/bin/env bash
# scanner-watchdog.sh — restart a silently-wedged scanner process.
#
# The scanner can become wedged: alive PID, sleep loop intact, but emits no
# events. This script reads the heartbeat file written every tick and kills
# the scanner if it hasn't updated in STALE_THRESHOLD seconds (default:
# 2 × LOOP_SCANNER_INTERVAL, or 900s). launchd KeepAlive then restarts it.
#
# Usage:
#   scanner-watchdog.sh            # check and restart if stale
#   scanner-watchdog.sh --dry-run  # log what would happen without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HB_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 + 60 ))}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# Compute age of the heartbeat file in seconds, or a large sentinel if absent.
_heartbeat_age() {
    if [ ! -f "$HB_FILE" ]; then
        echo 999999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HB_FILE" 2>/dev/null || stat -c%Y "$HB_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive — no action needed"
    exit 0
fi

# Heartbeat is stale. Read scanner PID from lock file.
pid=""
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -z "$pid" ]; then
    log "WARN: heartbeat stale but no lock file found — scanner may not be running"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "WARN: heartbeat stale but PID $pid is already dead — launchd should restart scanner"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $pid (stale for ${age}s)"
    exit 0
fi

log "killing stale scanner PID $pid (no heartbeat for ${age}s) — launchd will restart"
kill "$pid" 2>/dev/null || true
