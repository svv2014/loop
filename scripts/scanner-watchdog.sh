#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops emitting heartbeats.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is absent or its mtime
# is older than STALE_THRESHOLD_SECONDS (default: 2 × LOOP_SCANNER_INTERVAL,
# minimum 600s), the scanner is considered wedged and is restarted:
#   macOS:  launchctl kickstart -k gui/<uid>/com.user.loop-scanner
#   Linux:  kill the PID from /tmp/loop-scanner.lock (launchd/cron restarts it)
#
# Designed to run every 5 min via launchd (StartInterval=300) or cron (*/5).
# Safe to run even when the scanner is healthy — it is a no-op in that case.
#
# Flags:
#   --dry-run   log what would happen without actually restarting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2× poll interval, but no less than 600s (10 min).
_double=$(( POLL_INTERVAL * 2 ))
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE:-$(( _double > 600 ? _double : 600 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"
LAUNCHD_LABEL="com.user.loop-scanner"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"

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

# Redirect output to the watchdog log (unless dry-run, where stdout is fine).
$DRY_RUN || exec 1>>"$LOG_FILE" 2>>"$LOG_FILE"

# Determine heartbeat age in seconds. Returns a very large number when the
# file is absent so the stale check still triggers.
_heartbeat_age() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo 999999
        return
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age)
log "heartbeat_age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy — no action"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# macOS: use launchctl kickstart to replace the running instance cleanly.
if command -v launchctl >/dev/null 2>&1; then
    local_uid=$(id -u)
    if launchctl kickstart -k "gui/${local_uid}/${LAUNCHD_LABEL}" 2>/dev/null; then
        log "restarted via launchctl kickstart gui/${local_uid}/${LAUNCHD_LABEL}"
        exit 0
    fi
    log "WARN: launchctl kickstart failed — falling back to kill"
fi

# Fallback (Linux / launchctl unavailable): kill the PID so the cron/supervisor
# respawns the scanner on next schedule.
if [ -f "$SCANNER_LOCK" ]; then
    local_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        kill "$local_pid" && log "killed scanner PID ${local_pid}"
        rm -f "$SCANNER_LOCK"
        exit 0
    fi
fi

log "WARN: no running scanner PID found — lock file absent or stale; nothing to kill"
