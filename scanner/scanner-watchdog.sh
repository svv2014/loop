#!/usr/bin/env bash
# scanner-watchdog.sh — Restart scanner if its heartbeat file goes stale.
#
# Run every 5 minutes via launchd (StartInterval 300) or cron (*/5 * * * *).
# If the scanner has not updated ${LOOP_LOG_DIR}/scanner-heartbeat within
# 2 × LOOP_SCANNER_INTERVAL seconds, kill its PID (launchd's KeepAlive
# will restart it automatically within ThrottleInterval seconds).
#
# Usage:
#   scanner-watchdog.sh          # normal check
#   scanner-watchdog.sh --dry-run  # report staleness without killing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
hb_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - hb_mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: heartbeat stale: age=${age}s > threshold=${STALE_THRESHOLD}s"

if $DRY_RUN; then
    log "dry-run: would kill scanner and let launchd restart it"
    exit 0
fi

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing stale scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    log "scanner killed — launchd/cron will restart it"
else
    log "no live scanner PID found in $LOCK_FILE — nothing to kill"
fi
