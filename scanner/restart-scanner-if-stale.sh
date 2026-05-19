#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If its mtime is older than
# STALE_THRESHOLD_SECONDS (default: 2 × LOOP_SCANNER_INTERVAL = 10 min),
# kills the scanner PID (from /tmp/loop-scanner.lock) and either
# restarts via launchctl (macOS) or by exec-ing a fresh scanner process
# (Linux / manual mode).
#
# Intended to run every 5 minutes via launchd (macOS) or cron (Linux).
# Safe to run concurrently with a healthy scanner — it exits immediately
# when the heartbeat is fresh.
#
# Flags:
#   --dry-run   report stale/healthy status without taking action
#   --once      (default) single check; reserved for future loop mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

_file_age_seconds() {
    local f="$1"
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Returns 0 (true) if the scanner looks healthy based on the heartbeat file.
_scanner_is_healthy() {
    [ -f "$HEARTBEAT_FILE" ] || return 1
    local age
    age=$(_file_age_seconds "$HEARTBEAT_FILE")
    [ "$age" -lt "$STALE_THRESHOLD" ]
}

_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 1
    cat "$LOCK_FILE" 2>/dev/null || true
}

_restart_scanner() {
    local pid
    pid=$(_scanner_pid || true)

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        $DRY_RUN || kill "$pid" 2>/dev/null || true
    fi

    if $DRY_RUN; then
        log "DRY-RUN: would restart scanner"
        return 0
    fi

    # macOS: launchd manages KeepAlive — killing the process is enough;
    # launchd will restart it. Use kickstart for an immediate restart.
    if command -v launchctl >/dev/null 2>&1; then
        log "kickstarting launchd service: $LAUNCHD_LABEL"
        launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null \
            || launchctl start "$LAUNCHD_LABEL" 2>/dev/null \
            || log "WARN: launchctl restart failed; launchd KeepAlive will handle it"
        return 0
    fi

    # Linux / no launchd: start a detached scanner process.
    log "starting scanner directly (no launchd)"
    nohup "$LOOP_ROOT/scanner/scanner.sh" \
        >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
    log "scanner started (PID $!)"
}

if _scanner_is_healthy; then
    local_age=$(_file_age_seconds "$HEARTBEAT_FILE")
    log "healthy (heartbeat age=${local_age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "WARN: heartbeat file missing — scanner may never have started"
else
    stale_age=$(_file_age_seconds "$HEARTBEAT_FILE")
    log "STALE: heartbeat age=${stale_age}s > threshold=${STALE_THRESHOLD}s — restarting"
fi

_restart_scanner
