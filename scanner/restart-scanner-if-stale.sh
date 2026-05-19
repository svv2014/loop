#!/usr/bin/env bash
# restart-scanner-if-stale.sh — watchdog: restart the scanner if its heartbeat
# file has not been updated recently, which indicates the scanner is silently
# wedged (alive PID, sleep loop intact, but no tick activity).
#
# Intended to run every 5 minutes via launchd (macOS) or cron (Linux). Because
# the scanner plist uses KeepAlive=true, killing the wedged PID is sufficient —
# launchd will restart the scanner automatically within ThrottleInterval seconds.
#
# Configuration (via loop.env or environment):
#   LOOP_SCANNER_STALE_THRESHOLD — seconds before heartbeat is considered stale
#                                   (default: 900 = 3 × default 300 s poll interval)
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]
#   restart-scanner-if-stale.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

# 900 s = 3 × default 300 s poll interval; tolerates one slow tick before
# raising a false alarm.
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-900}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK_FILE="/tmp/loop-scanner.lock"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# If the heartbeat file doesn't exist, the scanner may have just started or
# the operator upgraded before the first tick wrote one. Do not restart; wait.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file missing — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s) — triggering restart"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# Read the scanner PID from the lock file and kill the wedged process.
# launchd (KeepAlive=true) will restart it automatically.
scanner_pid=""
if [ -f "$SCANNER_LOCK_FILE" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner (PID $scanner_pid) — launchd/supervisor will restart"
    kill "$scanner_pid" || true
else
    log "scanner PID not alive; attempting launchctl kickstart"
    if command -v launchctl >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed (scanner may not be loaded as a LaunchAgent)"
    fi
fi
