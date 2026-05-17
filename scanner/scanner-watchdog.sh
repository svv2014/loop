#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a silently-wedged scanner.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the heartbeat file is older than STALE_THRESHOLD seconds, the scanner is
# considered stuck: it is killed and launchd/cron restarts it automatically.
#
# Designed to run every 5 minutes via launchd (StartInterval=300) or cron.
#
# Env / config:
#   LOOP_SCANNER_INTERVAL  — poll interval in seconds (default 300).
#                            STALE_THRESHOLD defaults to 2× this value.
#   LOOP_WATCHDOG_STALE_THRESHOLD — override stale threshold directly (seconds).
#   LOOP_SCANNER_LOCK      — path to scanner singleton lock (default /tmp/loop-scanner.lock)
#
# Flags:
#   --dry-run   report what would happen; do not kill/restart anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
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
# Prints the age of the file in seconds. Returns 1 if the file does not exist.
_file_age_seconds() {
    local f="$1"
    [ -f "$f" ] || return 1
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — read the PID from the lock file if the process is alive.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 1
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

log "tick (stale-threshold=${STALE_THRESHOLD}s heartbeat=${HEARTBEAT_FILE})"

# 1. If the heartbeat file does not exist at all, the scanner has never started
#    (or LOOP_LOG_DIR changed). Nothing to do — launchd will start it.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner not yet started or first run; skipping"
    exit 0
fi

heartbeat_age=$(_file_age_seconds "$HEARTBEAT_FILE")

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy (heartbeat age=${heartbeat_age}s < threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat age=${heartbeat_age}s >= ${STALE_THRESHOLD}s — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# 2. Kill the stuck scanner process so launchd (KeepAlive=true) restarts it.
pid=$(_scanner_pid 2>/dev/null || true)
if [ -n "$pid" ]; then
    log "killing scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    # Give it a moment to exit, then SIGKILL if still alive.
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log "SIGKILL scanner PID $pid (did not exit after SIGTERM)"
        kill -9 "$pid" 2>/dev/null || true
    fi
    # Remove stale lock so the launchd-restarted scanner can acquire it.
    rm -f "$LOCK_FILE"
    log "scanner PID $pid killed; launchd will restart it"
else
    log "no live scanner PID in $LOCK_FILE — removing stale lock if present"
    rm -f "$LOCK_FILE"
    # On macOS, request launchd to start the scanner label immediately.
    if command -v launchctl >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed (scanner may not be loaded as a LaunchAgent)"
    fi
fi

log "tick done"
