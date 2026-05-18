#!/usr/bin/env bash
# check-scanner-liveness.sh — watchdog for the continuous scanner process.
#
# Reads the heartbeat file written by scanner.sh on every tick. If the file
# is absent or its mtime is older than LOOP_SCANNER_LIVENESS_THRESHOLD seconds
# (default: 2 × LOOP_SCANNER_INTERVAL, i.e. 600s), the scanner is considered
# wedged: its PID (from the lock file) is killed so that launchd (macOS) or
# cron (Linux) can restart it.
#
# Designed to run every 5 minutes (launchd StartInterval=300 / cron */5).
#
# Flags:
#   --dry-run   print what would be done without killing the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Default threshold: 2 × poll interval (600s for the default 300s cadence).
LIVENESS_THRESHOLD="${LOOP_SCANNER_LIVENESS_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

# No heartbeat file means the scanner has never ticked (or was just started).
# Don't kill it — give it at least one full threshold window to write.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found (${HEARTBEAT_FILE}) — scanner may not have started yet; skipping"
    exit 0
fi

# Compute heartbeat age in seconds.
heartbeat_age=$(( $(date +%s) - $(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))

if [ "$heartbeat_age" -lt "$LIVENESS_THRESHOLD" ]; then
    log "OK: heartbeat age=${heartbeat_age}s threshold=${LIVENESS_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${heartbeat_age}s exceeds threshold=${LIVENESS_THRESHOLD}s"

# Read the scanner PID from the lock file.
if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file at ${LOCK_FILE} — scanner not running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file empty — cannot determine scanner PID"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "PID ${scanner_pid} is not alive — stale lock file; launchd will restart scanner"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${scanner_pid}"
    exit 0
fi

log "killing wedged scanner PID ${scanner_pid} (launchd will restart it)"
kill "$scanner_pid" 2>/dev/null || true
