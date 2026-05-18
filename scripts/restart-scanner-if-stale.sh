#!/usr/bin/env bash
# restart-scanner-if-stale.sh — liveness watchdog for scanner.sh.
#
# Reads the scanner heartbeat file written at the start of every scan tick.
# If the heartbeat is older than STALE_THRESHOLD seconds the scanner is
# considered wedged (alive PID, broken event loop) and is killed; launchd
# KeepAlive=true restarts it automatically.
#
# Intended to run on a short interval (5 min) via a launchd StartInterval
# job (com.user.loop-scanner-watchdog). It is a no-op when the scanner is
# not running or when --dry-run is passed.
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]
#
# Environment:
#   LOOP_LOG_DIR        — directory containing scanner-heartbeat (required)
#   LOOP_SCANNER_INTERVAL — scanner poll interval in seconds (default: 300)
#   LOOP_WATCHDOG_STALE_MULTIPLIER — heartbeat age multiplier before restart
#                         (default: 2; i.e. stale after 2 × poll_interval)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

DRY_RUN=false
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $_arg" >&2; exit 2 ;;
    esac
done

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_MULTIPLIER="${LOOP_WATCHDOG_STALE_MULTIPLIER:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_MULTIPLIER ))

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

# Heartbeat file must exist for the watchdog to act — if it doesn't exist the
# scanner has never run (first boot) or was just restarted.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found (${HEARTBEAT_FILE}) — scanner not yet started or just restarted; no action"
    exit 0
fi

# Compute age of heartbeat file in seconds.
_now=$(date +%s)
_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
_age=$(( _now - _mtime ))

log "heartbeat age=${_age}s threshold=${STALE_THRESHOLD}s (${STALE_MULTIPLIER}×${POLL_INTERVAL}s)"

if [ "$_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive — no action"
    exit 0
fi

log "WARN: scanner heartbeat stale (${_age}s > ${STALE_THRESHOLD}s)"

# Read the scanner's PID from its lock file and signal it.
if [ ! -f "$LOCK_FILE" ]; then
    log "lock file not found (${LOCK_FILE}) — scanner not running; no action"
    exit 0
fi
_scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)

if [ -z "$_scanner_pid" ]; then
    log "lock file empty — cannot determine scanner PID; no action"
    exit 0
fi

if ! kill -0 "$_scanner_pid" 2>/dev/null; then
    log "scanner PID ${_scanner_pid} not alive — already dead or being restarted; no action"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${_scanner_pid} (launchd will restart)"
    exit 0
fi

log "killing wedged scanner PID ${_scanner_pid} — launchd will restart"
kill "$_scanner_pid" 2>/dev/null || true
