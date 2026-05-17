#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Run every 5 min via launchd (macOS) or cron (Linux). Reads
# ${LOOP_LOG_DIR}/scanner-heartbeat; if its mtime is older than
# 2 × LOOP_SCANNER_INTERVAL (default 600s), kills the scanner PID and logs.
# launchd KeepAlive=true on the scanner plist auto-restarts it within seconds.
#
# Flags:
#   --dry-run   report stale state without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HB_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -12
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HB_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

hb_mtime=$(stat -f%m "$HB_FILE" 2>/dev/null || stat -c%Y "$HB_FILE" 2>/dev/null || echo 0)
age=$(( $(date +%s) - hb_mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${age}s > ${STALE_THRESHOLD}s — scanner appears wedged"

pid=""
if [ -f "$SCANNER_LOCK" ]; then
    pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "dry-run: would kill scanner PID ${pid:-unknown}"
    exit 0
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" && log "killed scanner PID $pid — launchd/cron will restart"
else
    log "scanner lock PID (${pid:-none}) not running — launchd/cron should restart automatically"
fi
