#!/usr/bin/env bash
# scanner-watchdog.sh — detect a wedged scanner and restart it.
#
# Runs every 5 min via launchd (macOS) or cron (Linux).
# If scanner-heartbeat is older than 2 × LOOP_SCANNER_INTERVAL (default 600s),
# kills the scanner PID (launchd KeepAlive or the Linux fallback restarts it).
#
# Flags:
#   --dry-run   print what would happen without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
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

log "tick (stale-threshold=${STALE_THRESHOLD}s heartbeat=${HEARTBEAT_FILE} dry-run=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

age=$(( $(date +%s) - $(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok (heartbeat age=${age}s < ${STALE_THRESHOLD}s)"
    exit 0
fi

log "STALE heartbeat age=${age}s >= ${STALE_THRESHOLD}s — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# Kill the wedged scanner. On macOS, launchd KeepAlive=true restarts it
# automatically. On Linux, fall back to a manual nohup restart.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
    else
        log "lock file present but PID ${pid:-<empty>} is not alive; removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file found; scanner may have already exited"
fi

# On Linux without launchd, start a fresh scanner instance.
if ! command -v launchctl >/dev/null 2>&1; then
    log "no launchctl — starting scanner via nohup"
    nohup "$LOOP_ROOT/scanner/scanner.sh" >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
    log "scanner restarted (PID $!)"
else
    log "launchd detected — scanner will auto-restart via KeepAlive"
fi

log "done"
