#!/usr/bin/env bash
# scanner-watchdog.sh — detect and recover a silently-wedged scanner.
#
# Checks ${LOOP_LOG_DIR}/scanner-heartbeat mtime. If the file is older than
# 2 × LOOP_SCANNER_INTERVAL (default 10 min), the scanner is considered wedged:
# its lock-file PID is killed and launchd KeepAlive auto-restarts it within
# ThrottleInterval seconds.
#
# On Linux (cron), the stale lock is cleared so the next cron invocation
# starts a fresh scanner process.
#
# Designed to run every 5 minutes via launchd StartInterval or cron.
#
# Flags:
#   --dry-run   report staleness without killing/restarting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HEARTBEAT="${LOOP_LOG_DIR}/scanner-heartbeat"
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

if [ ! -f "$HEARTBEAT" ]; then
    log "no heartbeat file found at $HEARTBEAT — scanner not yet started or LOOP_LOG_DIR unconfigured"
    exit 0
fi

heartbeat_mtime=$(stat -f%m "$HEARTBEAT" 2>/dev/null || stat -c%Y "$HEARTBEAT" 2>/dev/null || echo 0)
age=$(( $(date +%s) - heartbeat_mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "ALERT: scanner heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# Kill the wedged scanner so launchd KeepAlive (macOS) or cron (Linux) restarts it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    else
        log "lock file present but PID ${pid:-<empty>} not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
fi

# On macOS launchd, KeepAlive=true auto-restarts the scanner after the kill.
# kickstart is belt-and-braces for the case where launchd needs nudging.
if command -v launchctl >/dev/null 2>&1; then
    log "kickstarting com.user.loop-scanner via launchctl"
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        || log "WARN: launchctl kickstart failed — KeepAlive will auto-restart shortly"
else
    log "non-macOS: stale lock cleared — cron will restart scanner on next invocation"
fi
