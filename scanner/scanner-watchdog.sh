#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# The scanner writes a timestamp to ${LOOP_LOG_DIR}/scanner-heartbeat at the
# top of every poll tick. This watchdog checks that file's mtime; if no
# update has occurred within STALE_THRESHOLD_SECONDS it kills the scanner PID
# (found via /tmp/loop-scanner.lock) so launchd (KeepAlive=true) or cron
# restarts it immediately.
#
# Designed to run every 5 min via launchd StartInterval or cron:
#   launchd: StartInterval 300, templates/launchd/com.user.loop-scanner-watchdog.plist.template
#   cron:    */5 * * * * /path/to/loop/scanner/scanner-watchdog.sh
#
# Flags:
#   --dry-run   print diagnosis to stdout without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Kill after 2× poll interval with no heartbeat update (default 10 min).
STALE_THRESHOLD_SECONDS="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
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

# _heartbeat_age_seconds — seconds since heartbeat file was last written.
# Returns a large sentinel when the file does not exist.
_heartbeat_age_seconds() {
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

age=$(_heartbeat_age_seconds)
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD_SECONDS}s"

if [ "$age" -lt "$STALE_THRESHOLD_SECONDS" ]; then
    log "scanner is alive — no action needed"
    exit 0
fi

# Heartbeat is stale — find and kill the scanner PID.
if [ ! -f "$LOCK_FILE" ]; then
    log "WARN: heartbeat stale but no lock file at $LOCK_FILE — scanner may already be down; launchd will restart it"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "WARN: lock file empty — removing stale lock so scanner can restart"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "WARN: PID $scanner_pid in lock file is already dead — removing stale lock"
    $DRY_RUN || rm -f "$LOCK_FILE"
    exit 0
fi

log "ALERT: scanner PID $scanner_pid has not updated heartbeat for ${age}s — killing for launchd restart"
if $DRY_RUN; then
    log "DRY-RUN: would kill PID $scanner_pid"
else
    kill "$scanner_pid" 2>/dev/null || true
    log "sent SIGTERM to PID $scanner_pid"
fi
