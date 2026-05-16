#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it stops emitting heartbeats.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file is absent or its mtime is older than 2 × LOOP_SCANNER_INTERVAL
# (default 10 min), the scanner is considered wedged: kill its PID (from the
# lock file) and, on macOS, use launchctl kickstart to bring it back; on Linux
# the scanner's cron entry will relaunch it on the next tick.
#
# Run every 5 min via launchd StartInterval (macOS) or cron (Linux).
# Flags:
#   --dry-run   report stale state but do not kill or restart
#   --once      no-op alias (default behaviour is already single-sweep)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

log "tick start (threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

now=$(date +%s)

# Determine heartbeat age.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "WARN: heartbeat file absent — scanner may not have started yet"
    exit 0
fi

mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "ok: heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — scanner appears wedged"

# Read the scanner's PID from the lock file and kill it so launchd/cron restarts it.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY: would kill scanner PID=${scanner_pid:-unknown} and trigger restart"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID=$scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    sleep 2
fi

# On macOS, use launchctl kickstart so the scanner is restarted immediately
# rather than waiting for launchd's ThrottleInterval.
if [ "$(uname -s)" = "Darwin" ]; then
    # Derive the launchd service domain from the current UID.
    local_uid=$(id -u)
    if launchctl kickstart -k "gui/${local_uid}/com.user.loop-scanner" 2>/dev/null; then
        log "kickstarted com.user.loop-scanner via launchctl"
    else
        log "WARN: launchctl kickstart failed — launchd will auto-restart on ThrottleInterval"
    fi
else
    log "Linux: scanner will be restarted by the next cron tick"
fi

log "tick done"
