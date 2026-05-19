#!/usr/bin/env bash
# scanner-watchdog.sh — restart a wedged scanner based on heartbeat staleness.
#
# The scanner writes a heartbeat file (${LOOP_LOG_DIR}/scanner-heartbeat) at the
# start of every tick. If that file's mtime is older than 2 × POLL_INTERVAL
# (default 10 min) the scanner is considered wedged: kill its PID (from the
# lock file) and — on macOS — kick launchd to restart it. launchd KeepAlive
# handles the restart; on Linux the cron entry starts a fresh --once sweep.
#
# Usage:
#   scanner-watchdog.sh            # single check (suitable for cron / launchd StartInterval)
#   scanner-watchdog.sh --dry-run  # print what would happen, no kills

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
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

log "check (threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo "$now")
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat fresh (age=${age}s < ${STALE_THRESHOLD}s) — scanner healthy"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= ${STALE_THRESHOLD}s) — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID and signal launchd/cron to restart"
    exit 0
fi

# Kill the wedged scanner process.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give launchd a moment to acknowledge the exit before kickstart.
        sleep 2
    else
        log "lock file present but PID ${pid:-<empty>} not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file found — scanner may have already exited"
fi

# On macOS, kick launchd to restart the scanner immediately rather than
# waiting for the default ThrottleInterval.
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list com.user.loop-scanner >/dev/null 2>&1; then
        log "kickstarting com.user.loop-scanner via launchctl"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl start com.user.loop-scanner 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd KeepAlive will restart on its own"
    else
        log "com.user.loop-scanner not registered with launchd — KeepAlive restart not available"
    fi
else
    log "launchctl not found (Linux?) — cron will start a fresh --once sweep on next tick"
fi

log "watchdog action complete"
