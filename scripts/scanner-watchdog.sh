#!/usr/bin/env bash
# scanner-watchdog.sh — detect a silently-wedged scanner and kill it so launchd restarts it.
#
# The scanner writes ${LOOP_LOG_DIR}/scanner-heartbeat on every tick. If that
# file's mtime is older than STALE_THRESHOLD (default 2 × POLL_INTERVAL = 600s),
# the scanner is considered wedged; its PID is sent SIGTERM so launchd
# (KeepAlive=true) or cron restarts it immediately.
#
# Run every 5 minutes via launchd (macOS) or cron (Linux):
#   macOS: com.user.loop-scanner-watchdog.plist (StartInterval 300)
#   Linux: */5 * * * * /path/to/scripts/scanner-watchdog.sh
#
# Flags:
#   --dry-run   report stale state without sending SIGTERM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2 × poll interval. Configurable via LOOP_WATCHDOG_STALE_THRESHOLD.
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

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

log "tick (stale-threshold=${STALE_THRESHOLD}s dry-run=${DRY_RUN})"

# No heartbeat file yet — scanner has never ticked or LOOP_LOG_DIR changed.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file at $HEARTBEAT_FILE — scanner not yet started or log dir changed"
    exit 0
fi

# Compute heartbeat age in seconds.
now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo "$now")
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat age=${age}s — scanner healthy"
    exit 0
fi

log "WARN: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID from $LOCK_FILE"
    exit 0
fi

# Read the scanner PID from its lock file and send SIGTERM.
# launchd (KeepAlive=true) will restart the scanner automatically.
if [ ! -f "$LOCK_FILE" ]; then
    log "WARN: no lock file at $LOCK_FILE — scanner may not be running"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "WARN: lock file is empty — cannot determine scanner PID"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "WARN: scanner PID $scanner_pid is not alive — lock is stale"
    exit 0
fi

log "sending SIGTERM to scanner PID $scanner_pid (launchd will restart)"
kill -TERM "$scanner_pid" 2>/dev/null || {
    log "WARN: could not send SIGTERM to PID $scanner_pid"
    exit 1
}
log "done — scanner PID $scanner_pid terminated"
