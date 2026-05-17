#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a wedged scanner process.
#
# The scanner can become silently stuck (alive PID, sleep loop intact) while
# emitting no events. This script runs every ~5 min via launchd/cron, checks
# the scanner-heartbeat mtime, and kills + restarts the scanner if stale.
#
# Stale threshold: 2 × POLL_INTERVAL (default 600 s = 10 min). A healthy
# scanner updates the heartbeat file on every tick, so two missed ticks means
# something is wrong.
#
# Usage:
#   scanner-watchdog.sh           # check and restart if stale
#   scanner-watchdog.sh --dry-run # report only, do not restart

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
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale if the heartbeat is older than 2 × poll interval.
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

log "tick (stale-threshold=${STALE_THRESHOLD}s dry-run=${DRY_RUN})"

# If the heartbeat file doesn't exist the scanner has never run or was just
# installed — not a restart trigger on its own.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file at $HEARTBEAT_FILE — scanner may not have started yet"
    exit 0
fi

now=$(date +%s)
hb_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - hb_mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat fresh (age=${age}s < threshold=${STALE_THRESHOLD}s) — scanner healthy"
    exit 0
fi

log "WARN: heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s) — scanner appears wedged"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

# Kill the wedged scanner so launchd (KeepAlive) auto-restarts it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give launchd a moment; if still alive, force-kill.
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            log "WARN: PID $pid still alive after SIGTERM — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
    else
        log "lock file present but PID '${pid:-<empty>}' is not alive — stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file at $LOCK_FILE — scanner may have already exited"
fi

# On macOS, kick launchd to restart the service immediately rather than waiting
# for KeepAlive's ThrottleInterval. Fail silently — launchd will restart anyway.
if command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        || log "launchctl kickstart not available — launchd will restart on next ThrottleInterval"
fi

log "scanner restart triggered"
