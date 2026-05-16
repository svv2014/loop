#!/usr/bin/env bash
# scanner-watchdog.sh — Liveness watchdog for the Loop scanner.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written every tick by scanner.sh).
# If the heartbeat is older than LOOP_SCANNER_WATCHDOG_STALE seconds (default:
# 2× poll interval = 600s), the scanner is considered silently wedged. The
# watchdog kills the scanner PID (from /tmp/loop-scanner.lock) so that launchd
# (macOS, KeepAlive=true) or the next cron invocation restarts it.
#
# Run every 5 minutes via launchd (macOS) or cron (Linux).
#
# Flags:
#   --dry-run   print what would happen, do not kill anything
#   --once      no-op alias (all invocations are single-sweep)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Default stale threshold: 2× poll interval (10 min for the default 5-min poll).
STALE_SECONDS="${LOOP_SCANNER_WATCHDOG_STALE:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
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

# _file_age_seconds <path>
# Returns the number of seconds since <path> was last modified.
# Falls back to a very large value (9999999) if the file is missing or
# stat is unavailable, so the watchdog treats a missing heartbeat as stale.
_file_age_seconds() {
    local path="$1"
    local mtime now
    if [ ! -f "$path" ]; then
        echo 9999999
        return 0
    fi
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s stale_threshold=${STALE_SECONDS}s"

if [ "$age" -lt "$STALE_SECONDS" ]; then
    log "scanner is live — nothing to do"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s >= ${STALE_SECONDS}s) — triggering restart"

# Read scanner PID from lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    if $DRY_RUN; then
        log "DRY-RUN: would kill scanner PID $scanner_pid"
    else
        log "killing wedged scanner PID $scanner_pid"
        kill "$scanner_pid" 2>/dev/null || true
        # Give the process a moment to exit, then force-kill if still alive.
        sleep 2
        if kill -0 "$scanner_pid" 2>/dev/null; then
            log "scanner PID $scanner_pid still alive — sending SIGKILL"
            kill -9 "$scanner_pid" 2>/dev/null || true
        fi
        # Remove stale lock so the next scanner invocation does not self-exit.
        rm -f "$LOCK_FILE"
        log "scanner killed; launchd/cron will restart it"
    fi
else
    # Scanner is not running (PID dead or lock absent). Remove stale lock if
    # present so the next invocation can acquire it cleanly.
    if [ -f "$LOCK_FILE" ]; then
        if $DRY_RUN; then
            log "DRY-RUN: would remove stale lock $LOCK_FILE (PID ${scanner_pid:-unknown} not alive)"
        else
            log "removing stale lock $LOCK_FILE (PID ${scanner_pid:-unknown} not alive)"
            rm -f "$LOCK_FILE"
        fi
    else
        log "scanner not running and no lock file — launchd/cron will start it on next tick"
    fi
fi
