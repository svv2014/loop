#!/usr/bin/env bash
# scanner-watchdog.sh — detect and recover a silently-wedged scanner.
#
# The scanner can become wedged (alive PID, sleep loop intact) but emit no
# events for hours. This watchdog checks the heartbeat file written by
# scanner.sh at every tick. If the heartbeat is stale for more than
# 2 × POLL_INTERVAL seconds, the scanner PID is killed so launchd/cron
# can restart it.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]
#
# Designed to run every 5 minutes via launchd (StartInterval 300) or cron.
# On macOS launchd setups, after killing the scanner PID it also tries
# `launchctl kickstart` to force an immediate restart without waiting for
# KeepAlive's ThrottleInterval.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2 × poll interval (default 10 min). Set
# LOOP_WATCHDOG_STALE_SECONDS to override.
STALE_SECONDS="${LOOP_WATCHDOG_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

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

# If the heartbeat file does not exist, the scanner may never have started or
# may be running a very old version — do not kill anything, just warn.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found: $HEARTBEAT_FILE — scanner may not have started yet"
    exit 0
fi

# Compute age of heartbeat file in seconds.
heartbeat_age=$(( $(date +%s) - $(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))
log "heartbeat age=${heartbeat_age}s stale_threshold=${STALE_SECONDS}s"

if [ "$heartbeat_age" -lt "$STALE_SECONDS" ]; then
    log "scanner is healthy (heartbeat ${heartbeat_age}s old)"
    exit 0
fi

log "WARN: scanner heartbeat stale (${heartbeat_age}s > ${STALE_SECONDS}s) — triggering restart"

# Read the scanner PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID ${scanner_pid:-unknown} and restart"
    exit 0
fi

# Kill the wedged scanner so launchd/cron can restart it.
if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    # Give it a moment; escalate to SIGKILL if still alive.
    sleep 2
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "scanner still alive after SIGTERM — sending SIGKILL"
        kill -9 "$scanner_pid" 2>/dev/null || true
    fi
else
    log "scanner PID ${scanner_pid:-unknown} not found — may have already exited"
fi

# Remove the lock file so the restarted scanner can acquire it immediately.
rm -f "$LOCK_FILE" 2>/dev/null || true

# On macOS, kick launchd to restart immediately instead of waiting for
# ThrottleInterval (60s default).
if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" >/dev/null 2>&1; then
        log "launchctl kickstart sent — scanner will restart immediately"
    else
        log "launchctl kickstart failed (will rely on KeepAlive ThrottleInterval)"
    fi
fi

log "restart triggered"
