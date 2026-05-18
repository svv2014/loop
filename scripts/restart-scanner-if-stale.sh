#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Scanner liveness watchdog.
#
# Fires every 5 minutes (via launchd StartInterval or cron */5).
# Reads the heartbeat file written each tick by scanner.sh.
# If the heartbeat is older than LOOP_SCANNER_STALE_THRESHOLD seconds
# (default 900 = 15 min, ~3x the default 300s poll interval) AND the
# scanner lock file PID is alive, kills the PID and removes the lock so
# launchd KeepAlive (macOS) or the next cron tick (Linux) restarts it.
#
# Environment variables:
#   LOOP_SCANNER_STALE_THRESHOLD  — stale age in seconds (default: 900)
#   LOOP_LOG_DIR                  — log directory (from loop.env / env.sh)
#
# Flags:
#   --dry-run   diagnose only, no kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-900}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -25
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age <path> — seconds since last modification; 0 if file absent.
_file_age() {
    [ -f "$1" ] || { echo 0; return; }
    local mtime now
    mtime=$(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner has not run yet; skipping"
    exit 0
fi

heartbeat_age=$(_file_age "$HEARTBEAT_FILE")
log "heartbeat age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive (heartbeat fresh)"
    exit 0
fi

# Heartbeat is stale — check whether a scanner process is holding the lock.
if [ ! -f "$LOCK_FILE" ]; then
    log "stale heartbeat but no lock file — scanner not running; nothing to kill"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
if [ -z "$scanner_pid" ]; then
    log "WARN: lock file empty — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "WARN: lock PID $scanner_pid not alive — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

# PID alive but heartbeat stale — scanner is wedged.
log "ALERT: scanner PID $scanner_pid alive but heartbeat stale (${heartbeat_age}s > ${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would kill PID $scanner_pid and remove $LOCK_FILE"
    exit 0
fi

kill "$scanner_pid" 2>/dev/null || true
rm -f "$LOCK_FILE"
# launchd KeepAlive restarts on macOS within ~60s; on Linux the next cron
# tick fires scanner.sh --once which clears the missing lock and runs normally.
log "killed PID $scanner_pid; launchd/cron will restart scanner"
