#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Scanner liveness watchdog.
#
# Checks the scanner heartbeat file written each tick by scanner.sh.
# If the heartbeat is older than STALE_THRESHOLD_SECONDS (default 900 = 15 min)
# AND the lock file still exists (i.e. the scanner PID is believed alive), kill
# the scanner process and let launchd / KeepAlive restart it.
#
# On Linux (cron), launchctl is unavailable; the script kills the PID and the
# cron entry for scanner.sh --once will resume on the next cron tick.
#
# Usage:
#   restart-scanner-if-stale.sh            # normal run
#   restart-scanner-if-stale.sh --dry-run  # print diagnosis only, no kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-900}"
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
# Returns seconds since the file was last modified (0 if file missing).
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo 0; return; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Determine heartbeat age.
heartbeat_age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have run yet; skipping"
    exit 0
fi

log "heartbeat age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive (heartbeat fresh)"
    exit 0
fi

# Heartbeat is stale. Try to get the scanner PID from the lock file.
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

# PID is alive but heartbeat is stale — scanner is wedged.
log "ALERT: scanner PID $scanner_pid is alive but heartbeat stale (${heartbeat_age}s > ${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would kill PID $scanner_pid and remove $LOCK_FILE"
    exit 0
fi

kill "$scanner_pid" 2>/dev/null || true
rm -f "$LOCK_FILE"

# On macOS, let launchd KeepAlive handle the restart (it will within ~60s).
# On Linux, the scanner is run via cron --once so it will restart on next tick.
log "killed PID $scanner_pid; launchd/cron will restart scanner"
