#!/usr/bin/env bash
# scanner-watchdog.sh — detect and recover a silently-wedged scanner.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file is older than STALE_THRESHOLD seconds (default: 2 × poll interval),
# the scanner is considered wedged: its PID (from the lock file) is killed so
# launchd (KeepAlive=true) or the cron entry restarts it automatically.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# It is intentionally single-shot and stateless.
#
# Flags:
#   --dry-run  report what would be done without killing the scanner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK_FILE:-/tmp/loop-scanner.lock}"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
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
# Prints the age of the file in seconds, or a very large number if absent.
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
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy — no action needed"
    exit 0
fi

# Scanner is stale. Read its PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID=${scanner_pid:-unknown} (stale for ${age}s)"
    exit 0
fi

log "WARN: scanner stale for ${age}s — triggering restart"

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    # Give launchd a moment to observe the exit before we return.
    sleep 2
fi

# On macOS, also kick launchd directly so the restart is immediate rather than
# waiting for launchd's ThrottleInterval.
if command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        || log "launchctl kickstart failed (scanner may restart on its own via KeepAlive)"
fi

log "restart triggered"
