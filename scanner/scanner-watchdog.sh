#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a wedged scanner process.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file's mtime is older than
# LOOP_SCANNER_WATCHDOG_STALE seconds (default: 2 * poll_interval = 600s),
# the scanner is considered wedged and is killed so launchd (macOS) or cron
# (Linux) restarts it on the next tick.
#
# Designed to run every 5 min via launchd StartInterval or cron */5.
#
# Flags:
#   --dry-run   report stale/alive status but do not kill the scanner
#   -h|--help   show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
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

log "check: heartbeat=${HEARTBEAT_FILE} threshold=${STALE_THRESHOLD}s dry=${DRY_RUN}"

# No heartbeat file — scanner may not have started yet or just restarted.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file found — scanner not yet started or recovering"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive"
    exit 0
fi

log "STALE: scanner heartbeat is ${age}s old (threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner — exiting without action"
    exit 0
fi

# Kill scanner via PID from lock file; launchd KeepAlive (or cron) restarts it.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "killing wedged scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give launchd a moment to notice the exit before kickstart.
        sleep 2
    else
        log "WARN: lock PID '${pid:-}' is not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
fi

# On macOS, kickstart the service explicitly so it does not wait for
# ThrottleInterval if it exited very recently.
if command -v launchctl >/dev/null 2>&1; then
    local_uid=$(id -u)
    if launchctl list com.user.loop-scanner >/dev/null 2>&1; then
        log "launchctl kickstart gui/${local_uid}/com.user.loop-scanner"
        launchctl kickstart -k "gui/${local_uid}/com.user.loop-scanner" 2>/dev/null \
            || log "WARN: kickstart failed — KeepAlive will handle restart"
    fi
fi

log "watchdog done — scanner should restart momentarily"
