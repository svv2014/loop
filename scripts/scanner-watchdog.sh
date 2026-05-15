#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner every tick).
# If the file is missing or its mtime is older than LOOP_SCANNER_WATCHDOG_STALE
# seconds (default: 2 * LOOP_SCANNER_INTERVAL = 600s), the watchdog kills the
# scanner process and kicks launchd (macOS) or waits for cron (Linux) to restart.
#
# Designed to run every 5 minutes via launchd (StartInterval 300) or cron.
#
# Flags:
#   --dry-run  print what would happen without killing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"
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

# Check heartbeat age.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent: $HEARTBEAT_FILE"
    age=$((STALE_THRESHOLD + 1))
else
    now=$(date +%s)
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo "$now")
    age=$(( now - mtime ))
fi

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat fresh (age=${age}s threshold=${STALE_THRESHOLD}s) — OK"
    exit 0
fi

log "STALE heartbeat (age=${age}s threshold=${STALE_THRESHOLD}s) — restarting scanner"

# Read scanner PID from the lock file and kill it.
scanner_pid=""
if [ -f "$SCANNER_LOCK" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    if $DRY_RUN; then
        log "DRY-RUN: would kill scanner PID $scanner_pid"
    else
        log "killing scanner PID $scanner_pid"
        kill "$scanner_pid" 2>/dev/null || true
        sleep 2
        kill -0 "$scanner_pid" 2>/dev/null && kill -9 "$scanner_pid" 2>/dev/null || true
    fi
else
    log "scanner PID ${scanner_pid:-unknown} not running — lock stale or already dead"
fi

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner service"
    exit 0
fi

# Remove the lock so the restarted scanner can acquire it.
rm -f "$SCANNER_LOCK"

# On macOS, kick launchd to restart the scanner immediately.
# On Linux (cron mode), killing the PID is enough — cron will relaunch it.
if [ "$(uname -s)" = "Darwin" ]; then
    uid=$(id -u)
    if launchctl kickstart -k "gui/${uid}/com.user.loop-scanner" 2>/dev/null; then
        log "launchctl kickstart triggered — scanner restarting"
    else
        log "WARN: launchctl kickstart failed — scanner will restart on next launchd interval"
    fi
else
    log "Linux: scanner will restart on next cron tick (cron mode uses --once, no long-running process)"
fi
