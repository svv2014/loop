#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file is stale.
#
# Designed to run every 5 min via launchd (macOS) or cron (Linux).
# If the scanner is alive and emitting events the heartbeat file mtime is
# updated on every tick (default 5 min). The watchdog treats the scanner as
# wedged when the heartbeat file is older than STALE_THRESHOLD_SECONDS and
# kills the PID stored in the lock file so launchd can auto-restart it.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]
#
# Environment (read from loop.env or inherit):
#   LOOP_LOG_DIR              — directory that holds scanner-heartbeat and loop-scanner.log
#   LOOP_SCANNER_INTERVAL     — scanner poll interval in seconds (default 300)
#   LOOP_WATCHDOG_STALE_MULT  — multiplier for stale threshold (default 2)
#   LOOP_SCANNER_LOCK         — path to the scanner lock file (default /tmp/loop-scanner.lock)
#
# Note: On macOS launchd restarts the scanner automatically when KeepAlive is
# set. On Linux (cron/systemd) you need a restart-on-kill mechanism in place
# (e.g. a systemd service with Restart=on-failure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

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

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_MULT="${LOOP_WATCHDOG_STALE_MULT:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_MULT ))

log "heartbeat=${HEARTBEAT_FILE} lock=${LOCK_FILE} stale_threshold=${STALE_THRESHOLD}s"

# If the heartbeat file doesn't exist yet the scanner may never have run or
# has never completed a tick — treat as not-yet-started rather than stale.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

# Compute age of the heartbeat file.
now=$(date +%s)
# stat is not portable: macOS uses -f%m, GNU/Linux uses -c%Y.
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is live (heartbeat ${age}s old < ${STALE_THRESHOLD}s threshold)"
    exit 0
fi

log "WARN: heartbeat is stale (${age}s > ${STALE_THRESHOLD}s) — scanner may be wedged"

# Read the PID from the lock file and send SIGTERM so launchd/systemd can
# restart it. Fall back to SIGKILL after a short grace period if needed.
if [ ! -f "$LOCK_FILE" ]; then
    log "lock file absent — scanner not running or already restarted; no action"
    exit 0
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$pid" ]; then
    log "lock file is empty — skipping kill"
    exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
    log "scanner PID ${pid} is already dead — lock file is stale"
    rm -f "$LOCK_FILE"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${pid}"
    exit 0
fi

log "killing wedged scanner PID ${pid}"
kill -TERM "$pid" 2>/dev/null || true

# Wait up to 10 s for graceful shutdown, then SIGKILL.
local_deadline=$(( $(date +%s) + 10 ))
while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$local_deadline" ]; then
        log "SIGTERM timed out — sending SIGKILL to PID ${pid}"
        kill -KILL "$pid" 2>/dev/null || true
        break
    fi
    sleep 1
done

log "scanner PID ${pid} terminated — launchd/systemd should restart it"
