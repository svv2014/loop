#!/usr/bin/env bash
# scanner-watchdog.sh — Detect a wedged scanner and restart it.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh on every tick).
# If the file is absent or its mtime is older than STALE_THRESHOLD seconds,
# the scanner is considered wedged: kill the PID in /tmp/loop-scanner.lock
# and — on macOS — use launchctl kickstart to let launchd restart it;
# on Linux, start a new scanner background process directly.
#
# Intended to run every 5 minutes via launchd (macOS) or cron (Linux).
# On macOS: installed by install.sh --bootstrap as com.user.loop-scanner-watchdog.
# On Linux: add to crontab: */5 * * * * /path/to/scanner/scanner-watchdog.sh
#
# Usage:
#   scanner-watchdog.sh           # normal mode
#   scanner-watchdog.sh --dry-run # print decision, do not kill/restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Treat scanner as stale if heartbeat is older than 2× poll interval.
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE"; }

# _heartbeat_age_seconds — return mtime age of HEARTBEAT_FILE in seconds,
# or a sentinel large value if the file doesn't exist.
_heartbeat_age_seconds() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "999999"
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _restart_scanner — kill the wedged scanner PID (if any) and restart.
_restart_scanner() {
    local pid=""
    if [ -f "$LOCK_FILE" ]; then
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        $DRY_RUN || kill "$pid" 2>/dev/null || true
        sleep 2
    fi

    if $DRY_RUN; then
        log "DRY-RUN: would restart scanner"
        return
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        # launchd has KeepAlive=true — killing the PID is sufficient; launchd
        # will restart it automatically. kickstart is belt-and-braces in case
        # the agent is in a throttled state.
        if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" >/dev/null 2>&1; then
            log "launchctl kickstart sent to com.user.loop-scanner"
        else
            log "kickstart failed or agent not loaded — relying on launchd KeepAlive"
        fi
    else
        # Linux (cron mode): scanner runs as --once entries, so no daemon to
        # restart. Remove stale lock file so the next cron tick can proceed.
        rm -f "$LOCK_FILE"
        log "stale lock removed; next cron tick will run the scanner"
    fi
}

age=$(_heartbeat_age_seconds)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -ge "$STALE_THRESHOLD" ]; then
    log "STALE: scanner heartbeat is ${age}s old (threshold ${STALE_THRESHOLD}s) — restarting"
    _restart_scanner
else
    log "OK: scanner is alive"
fi
