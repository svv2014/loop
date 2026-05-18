#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Liveness watchdog for the continuous scanner.
#
# Checks the scanner heartbeat file written at every scan tick.  If the file
# has not been touched within LOOP_SCANNER_WATCHDOG_STALE_SECONDS (default 900)
# the watchdog kills the scanner PID and lets launchd restart it.
#
# On Linux the scanner runs --once per cron tick and cannot get stuck in a
# persistent loop; this script exits immediately on non-macOS hosts.
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# Linux uses --once cron ticks; persistent wedge cannot happen there.
if [ "$(uname -s)" != "Darwin" ]; then
    log "non-macOS host — watchdog is a no-op on Linux (cron runs --once)"
    exit 0
fi

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
# 900s = 3× the default 300s poll interval; generous enough to tolerate a slow
# tick (heavy gh API calls, large backlogs) without false positives.
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-900}"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent (${HEARTBEAT_FILE}) — scanner may not have started yet; skipping"
    exit 0
fi

# Read the epoch written by scanner.sh.  Reading content is more reliable
# than mtime: mtime can be affected by filesystem events unrelated to the
# scanner (e.g., backup tools, log rotators touching the file).
LAST_BEAT=$(cat "$HEARTBEAT_FILE" 2>/dev/null | tr -cd '0-9' || echo 0)
[ -n "$LAST_BEAT" ] || LAST_BEAT=0
NOW=$(date +%s)
AGE=$(( NOW - LAST_BEAT ))

if [ "$AGE" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${AGE}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${AGE}s >= threshold=${STALE_THRESHOLD}s"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID and request launchd restart"
    exit 0
fi

# Kill the scanner PID recorded in the lock file; launchd KeepAlive restarts it.
if [ -f "$LOCK_FILE" ]; then
    SCANNER_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$SCANNER_PID" ] && kill -0 "$SCANNER_PID" 2>/dev/null; then
        log "killing wedged scanner PID $SCANNER_PID"
        kill "$SCANNER_PID" || true
    else
        log "lock file present but PID ${SCANNER_PID:-<empty>} not alive"
    fi
fi

# Belt-and-suspenders: launchctl kickstart stops any running instance and
# starts a fresh one, even if the kill above was already sufficient.
if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
    log "launchctl kickstart sent — scanner restarting"
else
    log "WARN: launchctl kickstart failed (scanner may have already restarted via KeepAlive)"
fi
