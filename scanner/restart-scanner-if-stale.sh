#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Scanner liveness watchdog.
#
# Reads the heartbeat file written by scanner.sh on every tick.
# If the file is absent or its mtime is older than LOOP_HEARTBEAT_STALE_SECONDS
# (default: 2× poll interval = 600s), the scanner is considered wedged and is
# forcibly restarted via launchctl (macOS) or by killing the lock-file PID (Linux).
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# On macOS: launchctl kickstart -k re-creates the process with KeepAlive in place.
# On Linux: kill the PID from the lock file; cron will spawn a fresh --once run
#           on the next tick (the continuous daemonised form is macOS-only).
#
# Usage (invoked by scheduler — no args needed):
#   scanner/restart-scanner-if-stale.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
# Two poll intervals before declaring the scanner wedged.
STALE_THRESHOLD="${LOOP_HEARTBEAT_STALE_SECONDS:-600}"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE"; }

# _heartbeat_age — prints age in seconds of the heartbeat file, or a very large
# number if the file is absent (treat missing file as maximally stale).
_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 999999
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — no action needed"
    exit 0
fi

log "WARN: scanner appears wedged (heartbeat ${age}s old) — restarting"

if [ "$(uname -s)" = "Darwin" ]; then
    # macOS: kickstart respects KeepAlive and replaces any running instance.
    local_uid=$(id -u)
    if launchctl kickstart -k "gui/${local_uid}/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart succeeded"
    else
        # Fallback: kill PID from lock file; launchd KeepAlive will relaunch.
        if [ -f "$LOCK_FILE" ]; then
            old_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                kill "$old_pid" && log "killed scanner PID $old_pid; launchd will restart"
            else
                log "lock file stale or empty — removing"
                rm -f "$LOCK_FILE"
            fi
        else
            log "no lock file found; scanner may have already exited"
        fi
    fi
else
    # Linux: kill PID from lock file; cron will spawn a fresh run on next tick.
    if [ -f "$LOCK_FILE" ]; then
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" && log "killed scanner PID $old_pid"
        else
            log "lock file stale or empty — removing"
            rm -f "$LOCK_FILE"
        fi
    else
        log "no lock file found; scanner may have already exited"
    fi
fi
