#!/usr/bin/env bash
# scanner-watchdog.sh — detect a silently-wedged scanner and force a restart.
#
# The scanner can appear alive (KeepAlive PID, sleep loop running) but emit
# no events for hours. The heartbeat file written at the top of each scan tick
# is the only signal external to the scanner process that it is doing useful
# work. This watchdog reads that file and kills the scanner if the heartbeat
# is stale, relying on launchd (KeepAlive) or cron to restart it.
#
# Stale threshold: 2 × LOOP_SCANNER_INTERVAL (default 300s → 600s).
# Runs every 5 min via launchd StartInterval / cron */5.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Kill after 2 missed ticks to tolerate transient slowness.
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

# _file_age_seconds <path>
# Returns the age of the file in seconds, or a large sentinel (9999999) if missing.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo 9999999
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action needed"
    exit 0
fi

# Heartbeat is stale. Read the scanner PID from its lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -z "$scanner_pid" ]; then
    log "WARN: heartbeat stale (${age}s) but no lock file found — scanner may already be stopped"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "WARN: heartbeat stale (${age}s), lock PID ${scanner_pid} is already dead"
    exit 0
fi

log "ALERT: scanner PID ${scanner_pid} heartbeat stale for ${age}s — killing for launchd restart"

if $DRY_RUN; then
    log "DRY-RUN: would kill -TERM $scanner_pid"
    exit 0
fi

kill -TERM "$scanner_pid" 2>/dev/null || kill -KILL "$scanner_pid" 2>/dev/null || true
log "sent SIGTERM to scanner PID ${scanner_pid} — launchd will restart it"
