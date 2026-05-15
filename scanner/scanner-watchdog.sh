#!/usr/bin/env bash
# scanner-watchdog.sh — Restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat mtime. If the file is older than
# LOOP_SCANNER_WATCHDOG_STALE_THRESHOLD seconds (default: 2 * POLL_INTERVAL = 600),
# the scanner is considered wedged: kill its PID (from /tmp/loop-scanner.lock)
# and, on macOS, kickstart it via launchctl so it restarts immediately.
# On Linux with no KeepAlive equivalent, just killing the PID is enough when
# cron re-spawns the scanner on the next interval.
#
# Run every 5 minutes via launchd StartInterval (macOS) or cron */5 (Linux).
#
# Flags:
#   --dry-run   report staleness without killing or restarting
#   --once      single check (default; reserved for future loop mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE"; }

# _file_age_seconds <path>
# Returns the age in seconds of the file's mtime, or a large number if missing.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo 999999
        return 0
    fi
    local now mtime
    now=$(date +%s)
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    echo $(( now - mtime ))
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat is stale (${age}s > ${STALE_THRESHOLD}s) — triggering restart"

# Read the scanner PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill PID ${scanner_pid:-<none>} and restart scanner"
    exit 0
fi

# Kill the wedged scanner so launchd/cron can restart it.
if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    # Give it a moment; if still alive, force-kill.
    sleep 2
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "scanner still alive after SIGTERM — sending SIGKILL"
        kill -9 "$scanner_pid" 2>/dev/null || true
    fi
else
    log "no live scanner PID found in lock file — lock may be stale"
    rm -f "$LOCK_FILE"
fi

# On macOS, kickstart the scanner immediately rather than waiting for launchd
# to notice the process exited.
if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl list "com.user.loop-scanner" >/dev/null 2>&1; then
        log "kickstarting com.user.loop-scanner via launchctl"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl start "com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd KeepAlive will restart on its own"
    fi
fi

log "restart triggered"
