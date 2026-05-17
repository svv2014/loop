#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops emitting heartbeats.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written every tick by scanner.sh).
# If the file is missing or its mtime exceeds 2 × POLL_INTERVAL (default 10 min),
# the scanner is considered wedged: kill the PID from /tmp/loop-scanner.lock so
# launchd (KeepAlive=true) or cron restarts it.
#
# Designed to run every 5 min via launchd StartInterval or cron.
# Linux fallback: if launchctl is absent, kill the PID and let cron or the
# process supervisor restart it independently.
#
# Flags:
#   --dry-run   print verdict without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
MAX_SILENCE=$(( POLL_INTERVAL * 2 ))
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
# Returns seconds since the file was last modified, or a large number if absent.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo 999999; return 0; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${MAX_SILENCE}s heartbeat=${HEARTBEAT_FILE}"

if [ "$age" -lt "$MAX_SILENCE" ]; then
    log "scanner is alive (age ${age}s < ${MAX_SILENCE}s) — nothing to do"
    exit 0
fi

log "WARN: scanner appears wedged — heartbeat silent for ${age}s (threshold=${MAX_SILENCE}s)"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# Kill the recorded PID so launchd / the supervisor restarts it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    else
        log "lock file present but PID ${pid:-<empty>} not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file at $LOCK_FILE — scanner may have already exited"
fi

# On macOS: kickstart via launchctl so launchd brings it back immediately
# rather than waiting for ThrottleInterval.
SCANNER_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list "$SCANNER_LABEL" >/dev/null 2>&1; then
        log "launchctl kickstart gui/$(id -u)/${SCANNER_LABEL}"
        launchctl kickstart "gui/$(id -u)/${SCANNER_LABEL}" 2>/dev/null \
            || launchctl start "$SCANNER_LABEL" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd will retry via KeepAlive"
    else
        log "launchd service $SCANNER_LABEL not loaded — KeepAlive will restart on next tick"
    fi
else
    log "launchctl not available — scanner will be restarted by its supervisor"
fi

log "watchdog done"
