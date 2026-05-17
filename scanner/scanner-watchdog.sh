#!/usr/bin/env bash
# scanner-watchdog.sh — restart the Loop scanner when its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat written by scanner.sh on every tick.
# If the file is older than LOOP_SCANNER_WATCHDOG_THRESHOLD seconds (default:
# 2 × LOOP_SCANNER_INTERVAL = 600s), the scanner is considered wedged: its PID
# (read from /tmp/loop-scanner.lock) is killed so launchd KeepAlive restarts it.
# On Linux (no launchd) the kill alone suffices; cron re-invokes scanner.sh
# --once on the next 5-minute tick.
#
# Usage:
#   scanner-watchdog.sh          # single check (designed for launchd / cron)
#   scanner-watchdog.sh --dry-run  # report state without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
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
# Print seconds since last modification. Supports macOS (BSD) and Linux (GNU) stat.
_file_age_seconds() {
    local path="$1"
    local mtime
    if mtime=$(stat -f%m "$path" 2>/dev/null); then
        echo $(( $(date +%s) - mtime ))
    elif mtime=$(stat -c%Y "$path" 2>/dev/null); then
        echo $(( $(date +%s) - mtime ))
    fi
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent ($HEARTBEAT_FILE) — scanner may not be running yet; skipping"
    exit 0
fi

age=$(_file_age_seconds "$HEARTBEAT_FILE")
if [ -z "$age" ]; then
    log "WARN: could not stat heartbeat file — skipping"
    exit 0
fi

log "heartbeat age=${age}s threshold=${THRESHOLD}s"

if [ "$age" -lt "$THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

# Scanner is wedged — kill it so launchd KeepAlive (macOS) or the next cron
# invocation (Linux) restarts it.
log "ALERT: heartbeat stale (${age}s >= ${THRESHOLD}s) — initiating restart"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    if [ -n "$scanner_pid" ]; then
        log "DRY-RUN: would kill scanner PID $scanner_pid and remove lock"
    else
        log "DRY-RUN: no scanner PID found; would remove stale lock if present"
    fi
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
else
    log "scanner PID ${scanner_pid:-<none>} not alive — clearing stale lock"
fi
# Remove the lock file so the restarted scanner can acquire it immediately.
rm -f "$LOCK_FILE" 2>/dev/null || true

log "done — launchd KeepAlive will restart the scanner automatically"
