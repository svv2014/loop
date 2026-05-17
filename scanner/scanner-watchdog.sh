#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a wedged scanner process.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh on every tick).
# If the heartbeat mtime is older than LOOP_SCANNER_WATCHDOG_STALE_SECONDS
# (default: 2 × LOOP_SCANNER_INTERVAL = 600s), kills the scanner PID and lets
# launchd (macOS) or cron (Linux) restart it.
#
# Designed to run every 5 min via launchd StartInterval or cron */5.
#
# Flags:
#   --dry-run   log what would be done without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-$(( 2 * POLL_INTERVAL ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy (heartbeat_age=${age}s threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s) — restarting scanner"

pid=$(head -1 "$HEARTBEAT_FILE" 2>/dev/null | tr -d '[:space:]' || true)

if $DRY_RUN; then
    log "DRY-RUN: would kill PID ${pid:-unknown} and rely on launchd/cron to restart"
    exit 0
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "sending SIGTERM to scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log "WARN: scanner PID $pid still alive after SIGTERM — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
else
    log "scanner PID ${pid:-unknown} already gone — launchd/cron will restart on next cycle"
fi

# On macOS, launchd KeepAlive=true restarts the scanner automatically after the kill.
# On Linux (cron --once mode), the next cron tick starts a fresh scanner run.
log "restart delegated to launchd (macOS) or next cron tick (Linux)"
