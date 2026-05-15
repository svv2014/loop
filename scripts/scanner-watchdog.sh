#!/usr/bin/env bash
# scanner-watchdog.sh — restart a silently-wedged scanner.
#
# Checks the mtime of ${LOOP_LOG_DIR}/scanner-heartbeat written by scanner.sh
# on every tick. If the file is older than 2×LOOP_SCANNER_INTERVAL (default
# 10 min) the scanner is assumed wedged: its PID is killed and the stale lock
# removed so launchd (KeepAlive) or cron can restart it cleanly.
#
# Designed to run every 5 min via launchd StartInterval / cron */5.
#
# Flags:
#   --dry-run   report staleness but do not kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
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

log "check (threshold=${STALE_THRESHOLD}s dry-run=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — scanner not yet started or does not support heartbeat"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner OK"
    exit 0
fi

log "WARN: heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and remove lock"
    exit 0
fi

# Kill the wedged scanner process.
pid=""
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "killing scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    sleep 2
fi

# Remove the stale lock so the restarted scanner can acquire it.
rm -f "$LOCK_FILE"

# On macOS, nudge launchd to restart the scanner immediately rather than
# waiting for the next KeepAlive cycle.
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list "com.user.loop-scanner" >/dev/null 2>&1; then
        log "kickstarting com.user.loop-scanner via launchctl"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl start "com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd will restart via KeepAlive"
    fi
fi

log "restart triggered"
