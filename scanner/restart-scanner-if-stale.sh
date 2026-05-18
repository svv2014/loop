#!/usr/bin/env bash
# restart-scanner-if-stale.sh — liveness watchdog for the loop scanner.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat written by scanner.sh every tick.
# If the heartbeat mtime is older than STALE_THRESHOLD (default: 2 × poll
# interval = 600 s), the scanner is considered wedged and is restarted.
#
# On macOS: launchctl kickstart -k gui/$UID/com.user.loop-scanner
# On Linux/cron: SIGTERM the PID from /tmp/loop-scanner.lock; cron restarts.
#
# Usage:
#   restart-scanner-if-stale.sh            # live mode
#   restart-scanner-if-stale.sh --dry-run  # log what would happen, don't act

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
LOCK_FILE="/tmp/loop-scanner.lock"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found ($HEARTBEAT_FILE) — scanner may not have started yet"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo "$now")
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# macOS: use launchctl so KeepAlive=true immediately respawns the scanner.
if command -v launchctl >/dev/null 2>&1 \
        && launchctl list com.user.loop-scanner >/dev/null 2>&1; then
    service_uid=$(id -u)
    log "restarting via launchctl kickstart -k gui/${service_uid}/com.user.loop-scanner"
    launchctl kickstart -k "gui/${service_uid}/com.user.loop-scanner" 2>/dev/null \
        || launchctl stop com.user.loop-scanner 2>/dev/null \
        || true
    exit 0
fi

# Linux / cron fallback: SIGTERM the PID recorded in the lock file. The cron
# entry for scanner.sh --once will spawn a fresh instance on the next tick.
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
        log "sending SIGTERM to stale scanner PID $scanner_pid"
        kill "$scanner_pid" 2>/dev/null || true
        exit 0
    fi
fi

log "no running scanner found to restart — launchd/cron will handle next start"
