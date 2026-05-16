#!/usr/bin/env bash
# scanner-watchdog.sh — restart the Loop scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh on every tick).
# If the file is missing or its mtime is older than LOOP_SCANNER_STALE_SECONDS
# (default 600 = 2 × the default 300-s poll interval), the scanner is considered
# wedged and is restarted.
#
# On macOS: restarts via launchctl kickstart -k (KeepAlive=true relaunches).
# On Linux (or macOS launchctl failure): kills the PID in /tmp/loop-scanner.lock;
# the process supervisor (cron/systemd) is expected to restart the scanner.
#
# Designed to run every 5 minutes via launchd StartInterval=300 or cron.
#
# Flags:
#   --dry-run   report stale state without restarting
#   --once      single sweep (default; reserved for future loop-mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_THRESHOLD="${LOOP_SCANNER_STALE_SECONDS:-600}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
LAUNCHD_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age_seconds <path> — prints seconds since file was last modified.
# Returns 1 if the file does not exist.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || return 1
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || return 1)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _kill_scanner_pid — send SIGTERM to the scanner PID recorded in the lock file.
_kill_scanner_pid() {
    if [ ! -f "$LOCK_FILE" ]; then
        log "WARN: lock file $LOCK_FILE not found — scanner may not be running"
        return
    fi
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "sending SIGTERM to scanner PID $pid"
        kill "$pid" 2>/dev/null || true
    else
        log "WARN: no live scanner PID in $LOCK_FILE"
    fi
}

# _restart_scanner — restart the scanner via launchctl (macOS) or PID kill (Linux).
_restart_scanner() {
    if [[ "$(uname)" == "Darwin" ]]; then
        local uid
        uid=$(id -u)
        log "restarting via launchctl kickstart -k gui/${uid}/${LAUNCHD_LABEL}"
        if launchctl kickstart -k "gui/${uid}/${LAUNCHD_LABEL}" 2>/dev/null; then
            return 0
        fi
        log "WARN: launchctl kickstart failed — falling back to PID kill"
    fi
    _kill_scanner_pid
}

log "tick start (stale-threshold=${STALE_THRESHOLD}s dry-run=${DRY_RUN})"

age=""
if ! age=$(_file_age_seconds "$HEARTBEAT_FILE" 2>/dev/null); then
    log "WARN: heartbeat file missing: ${HEARTBEAT_FILE} — scanner may never have started"
    if $DRY_RUN; then
        log "DRY-RUN: would restart scanner (no heartbeat file)"
    else
        _restart_scanner
    fi
    log "tick done"
    exit 0
fi

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -ge "$STALE_THRESHOLD" ]; then
    log "WARN: scanner heartbeat is stale (${age}s >= ${STALE_THRESHOLD}s) — restarting"
    if $DRY_RUN; then
        log "DRY-RUN: would restart scanner"
    else
        _restart_scanner
    fi
else
    log "scanner is alive (heartbeat age=${age}s)"
fi

log "tick done"
