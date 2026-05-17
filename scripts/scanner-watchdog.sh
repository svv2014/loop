#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Runs every 5 min via launchd StartInterval=300 (macOS) or cron (Linux).
# Checks ${LOOP_LOG_DIR}/scanner-heartbeat mtime. If older than
# LOOP_WATCHDOG_STALE_SECONDS (default: 2 × LOOP_SCANNER_INTERVAL = 600s),
# kills the scanner PID from /tmp/loop-scanner.lock so launchd KeepAlive
# can restart it.
#
# Flags:
#   --dry-run   log what would be killed, don't send SIGTERM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_SECONDS:-$(( ${LOOP_SCANNER_INTERVAL:-300} * 2 ))}"
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

# Heartbeat file must exist and be recent; absence is also treated as stale.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file missing: $HEARTBEAT_FILE"
else
    heartbeat_age=$(( $(date +%s) - $(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
                        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
                        || echo 0) ))
    if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
        log "heartbeat ok (age=${heartbeat_age}s < threshold=${STALE_THRESHOLD}s)"
        exit 0
    fi
    log "STALE heartbeat: age=${heartbeat_age}s >= threshold=${STALE_THRESHOLD}s"
fi

# Read the scanner PID from the lock file.
if [ ! -f "$LOCK_FILE" ]; then
    log "lock file missing ($LOCK_FILE) — scanner may not be running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file empty — nothing to kill"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already gone — launchd should restart it"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID $scanner_pid"
    exit 0
fi

log "killing stale scanner PID $scanner_pid (SIGTERM)"
kill "$scanner_pid" 2>/dev/null || true
# Give it 5 s to exit cleanly, then SIGKILL.
sleep 5
if kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid still alive — sending SIGKILL"
    kill -9 "$scanner_pid" 2>/dev/null || true
fi
log "done — launchd KeepAlive will restart the scanner"
