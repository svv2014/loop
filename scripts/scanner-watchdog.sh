#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file is stale.
#
# Runs every 5 min via launchd (macOS) or cron (Linux).
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat; if mtime > 2×POLL_INTERVAL seconds
# ago, kills the scanner process (from /tmp/loop-scanner.lock) and triggers
# a restart: launchd KeepAlive restarts automatically on kill; on Linux the
# stale lock is removed so the next cron tick starts a fresh instance.
#
# Flags:
#   --dry-run   print what would happen without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# If the heartbeat file does not exist yet the scanner may be starting up.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file — scanner may be starting"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo "$now")
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    exit 0
fi

log "STALE: scanner heartbeat is ${age}s old — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID and remove lock"
    exit 0
fi

# Kill the scanner process so launchd KeepAlive restarts it immediately.
pid=""
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "killing scanner PID $pid"
    kill "$pid" 2>/dev/null || true
    sleep 1
fi

# Remove stale lock so the new instance can acquire it cleanly.
rm -f "$LOCK_FILE"

# On macOS, kickstart the launchd job immediately instead of waiting for
# launchd's ThrottleInterval. Fall back silently on older launchctl.
if command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        || launchctl start com.user.loop-scanner 2>/dev/null \
        || true
fi

log "restart triggered"
