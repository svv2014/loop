#!/usr/bin/env bash
# scanner-watchdog.sh — liveness watchdog for scanner.sh.
# Checks ${LOOP_LOG_DIR}/scanner-heartbeat mtime. If the file is missing or
# older than STALE_THRESHOLD_SECONDS, kills the current scanner PID and
# restarts it via launchctl (macOS) or directly (Linux).
#
# Run every 5 minutes via launchd (macOS) or cron (Linux).
#
# Usage: scanner-watchdog.sh [--dry-run]
#
# Env overrides (all optional):
#   LOOP_SCANNER_INTERVAL              — scanner poll interval in seconds (default 300)
#   LOOP_SCANNER_WATCHDOG_THRESHOLD    — stale threshold override (default 2 × interval)

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

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
SCANNER_LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

heartbeat_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
now=$(date +%s)
age=$(( now - heartbeat_mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "OK heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — restarting scanner"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# Kill current scanner if its PID is in the lock file.
if [ -f "$SCANNER_LOCK_FILE" ]; then
    pid=$(cat "$SCANNER_LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing stale scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
    rm -f "$SCANNER_LOCK_FILE"
fi

# Restart via launchctl on macOS; direct on Linux.
if command -v launchctl >/dev/null 2>&1; then
    uid=$(id -u)
    if launchctl kickstart -k "gui/${uid}/com.user.loop-scanner" >/dev/null 2>&1; then
        log "restarted scanner via launchctl kickstart gui/${uid}/com.user.loop-scanner"
    else
        log "WARN: launchctl kickstart failed — scanner will auto-restart via KeepAlive"
    fi
else
    nohup "$LOOP_ROOT/scanner/scanner.sh" >> "$LOOP_LOG_DIR/loop-scanner.log" 2>&1 &
    log "restarted scanner directly (PID $!)"
fi
