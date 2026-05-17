#!/usr/bin/env bash
# scanner-watchdog.sh — detect a wedged scanner and trigger a restart.
#
# Runs every 5 minutes (via launchd StartInterval or cron). Checks the
# scanner-heartbeat file; if its mtime is older than 2 × LOOP_SCANNER_INTERVAL
# (default 10 min) the scanner is considered wedged: its PID is killed so
# launchd (KeepAlive=true) or cron restarts it automatically.
#
# On macOS with launchd, launchctl kickstart is attempted for an immediate
# restart rather than waiting out the ThrottleInterval.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale = 2× poll interval + 60s grace for scheduler jitter.
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 + 60 ))
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

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat absent — scanner may not have ticked yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s — scanner healthy"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — triggering restart"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# Kill the scanner PID so launchd/cron restarts it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing scanner PID $pid"
        kill "$pid" || true
    else
        log "lock PID '${pid}' not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file — scanner not running; nothing to kill"
fi

# macOS: kickstart immediately rather than waiting out ThrottleInterval.
if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
    if launchctl list com.user.loop-scanner >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd will auto-restart after ThrottleInterval"
    fi
fi

log "restart triggered"
