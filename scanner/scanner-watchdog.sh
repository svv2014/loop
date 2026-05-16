#!/usr/bin/env bash
# scanner-watchdog.sh — restart scanner if its heartbeat goes stale.
#
# Runs every 5 min via launchd (macOS) or cron (Linux). Reads the
# heartbeat timestamp written by scanner.sh on each tick. If the file
# is older than LOOP_SCANNER_WATCHDOG_THRESHOLD (default: 2x poll
# interval), kills the scanner PID and lets launchd/cron restart it.
#
# Flags:
#   --dry-run   report stale/healthy without killing or restarting
#   -h|--help   show this message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
WATCHDOG_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"
DRY_RUN=false

for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "unknown flag: $_arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file at $HEARTBEAT_FILE — scanner may not have started yet"
    exit 0
fi

_file_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0
}

heartbeat_age=$(( $(date +%s) - $(_file_mtime "$HEARTBEAT_FILE") ))
log "heartbeat age=${heartbeat_age}s threshold=${WATCHDOG_THRESHOLD}s"

if [ "$heartbeat_age" -lt "$WATCHDOG_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner heartbeat stale (${heartbeat_age}s > ${WATCHDOG_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

scanner_pid=""
if [ -f "$SCANNER_LOCK" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing stale scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    sleep 2
fi

# On macOS: launchd will restart the scanner automatically (KeepAlive=true).
# kickstart -k forces an immediate restart even if the process is already dead.
if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "launchd kickstart succeeded — scanner restarting"
    else
        log "WARN: launchctl kickstart failed; launchd will restart via KeepAlive"
    fi
else
    # Linux (cron mode): launch a background one-shot so this watchdog exits fast.
    log "Linux: launching scanner --once in background"
    nohup "$LOOP_ROOT/scanner/scanner.sh" --once \
        >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
fi

log "done"
