#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file is stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner on every tick).
# If the file is older than STALE_THRESHOLD seconds (default: 2 × poll interval),
# the scanner is considered wedged and is restarted:
#   macOS: launchctl kickstart -k gui/<uid>/com.user.loop-scanner
#   Linux: kill the PID recorded in /tmp/loop-scanner.lock; cron restarts it.
#
# Designed to run every 5 min via launchd (StartInterval 300) or cron.
#
# Flags:
#   --dry-run   print what would happen without taking action
#   --stale <s> override stale threshold in seconds (also LOOP_SCANNER_WATCHDOG_STALE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE:-$(( POLL_INTERVAL * 2 ))}"
SCANNER_LOCK="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --stale)      shift; STALE_THRESHOLD="$1" ;;
        --stale=*)    STALE_THRESHOLD="${1#--stale=}" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age_seconds <path>
# Prints the age of the file in seconds; returns 1 if file does not exist.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || return 1
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _restart_scanner
# Restarts the scanner via the OS-appropriate mechanism.
_restart_scanner() {
    local scanner_pid=""
    if [ -f "$SCANNER_LOCK" ]; then
        scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
    fi

    if [ "$(uname)" = "Darwin" ]; then
        local uid
        uid=$(id -u)
        log "macOS: kickstarting com.user.loop-scanner (uid=$uid)"
        if $DRY_RUN; then
            log "DRY-RUN: would run: launchctl kickstart -k gui/${uid}/com.user.loop-scanner"
            return 0
        fi
        if launchctl kickstart -k "gui/${uid}/com.user.loop-scanner" 2>/dev/null; then
            log "scanner restarted via launchctl kickstart"
            return 0
        fi
        # Fallback: kill the PID; launchd KeepAlive will restart the process.
        if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
            log "launchctl kickstart failed — killing PID $scanner_pid (launchd will restart)"
            kill "$scanner_pid" 2>/dev/null || true
        else
            log "WARN: launchctl kickstart failed and no live PID found — manual restart needed"
            return 1
        fi
    else
        # Linux: kill PID from lock file; cron will restart scanner on next tick.
        if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
            log "Linux: killing scanner PID $scanner_pid (cron will restart)"
            if $DRY_RUN; then
                log "DRY-RUN: would kill $scanner_pid"
                return 0
            fi
            kill "$scanner_pid" 2>/dev/null || true
        else
            log "WARN: no live scanner PID found — scanner may already be stopped"
        fi
    fi
}

age=$(_file_age_seconds "$HEARTBEAT_FILE" || echo "")

if [ -z "$age" ]; then
    log "heartbeat file missing: $HEARTBEAT_FILE — scanner not yet started or heartbeat not written"
    exit 0
fi

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy (age ${age}s < ${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s) — restarting scanner"
_restart_scanner
