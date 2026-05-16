#!/usr/bin/env bash
# restart-scanner-if-stale.sh — liveness watchdog for the Loop scanner.
#
# Reads the scanner heartbeat file written on every tick. If the file is
# older than LOOP_HEARTBEAT_STALE_SECONDS (default: 600 = 2 × 300s poll
# interval), the scanner is presumed wedged and is restarted:
#   macOS  — launchctl kickstart -k (launchd respects KeepAlive)
#   Linux  — kill the scanner PID so cron re-spawns it on the next minute
#
# Designed to run every 5 minutes via launchd (StartInterval=300) or cron.
# Does nothing if the heartbeat is fresh or the scanner is not running.
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
STALE_THRESHOLD="${LOOP_HEARTBEAT_STALE_SECONDS:-600}"
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
# Prints the age of the file in seconds, or a very large number if it
# does not exist (treating "never written" as infinitely stale).
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo 999999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy — nothing to do"
    exit 0
fi

log "WARN: heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — restarting scanner"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

if [ "$(uname -s)" = "Darwin" ]; then
    # launchd — kickstart kills the running instance (if any) and starts a
    # fresh one. -k = kill existing before starting. KeepAlive ensures it
    # stays up after future exits too.
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "restarted via launchctl kickstart"
    else
        # Fallback: kill the PID directly; launchd KeepAlive will revive it.
        if [ -f "$LOCK_FILE" ]; then
            local_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
            if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
                kill "$local_pid" 2>/dev/null && log "killed scanner PID $local_pid (launchd will restart)" || true
            else
                log "WARN: lock file stale or empty — scanner may already be down"
            fi
        else
            log "WARN: no lock file found; scanner may not be running"
        fi
    fi
else
    # Linux — kill the PID so cron re-spawns it on the next minute.
    if [ -f "$LOCK_FILE" ]; then
        local_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
            kill "$local_pid" 2>/dev/null && log "killed scanner PID $local_pid (cron will restart)" || true
        else
            log "WARN: lock file stale or empty — scanner may already be down"
        fi
    else
        log "WARN: no lock file found; scanner may not be running"
    fi
fi
