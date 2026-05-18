#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat is stale.
#
# The scanner writes an epoch timestamp to ${LOOP_LOG_DIR}/scanner-heartbeat
# at the start of every tick. If that file is older than STALE_THRESHOLD_SECONDS
# the scanner is considered wedged: we kill the PID in the lock file (if any)
# and ask launchd / systemd to restart it.
#
# Designed to run every 5 minutes via launchd StartInterval or cron.
#
# Usage:
#   scanner-watchdog.sh [--dry-run]
#
# Environment:
#   LOOP_SCANNER_INTERVAL        poll interval of the scanner (default 300s)
#   LOOP_WATCHDOG_STALE_MULT     multiplier applied to LOOP_SCANNER_INTERVAL to
#                                compute the stale threshold (default 2)
#   LOOP_SCANNER_LOCK_FILE       path to the scanner's PID lock (default
#                                /tmp/loop-scanner.lock)
#   LOOP_SCANNER_LAUNCHD_LABEL   launchd service label to kickstart on macOS
#                                (default com.user.loop-scanner)

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
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_MULT="${LOOP_WATCHDOG_STALE_MULT:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_MULT ))
LOCK_FILE="${LOOP_SCANNER_LOCK_FILE:-/tmp/loop-scanner.lock}"
LAUNCHD_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"

log "check: heartbeat=${HEARTBEAT_FILE} threshold=${STALE_THRESHOLD}s dry-run=${DRY_RUN}"

# Heartbeat file absent → scanner has never run or was just freshly installed.
# Treat as healthy to avoid false restarts on first boot.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found — scanner not yet started or dry-run mode; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — scanner appears wedged"

# Kill the lock-holder PID so launchd / cron restarts it cleanly.
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
        if $DRY_RUN; then
            log "DRY-RUN: would kill scanner PID $scanner_pid"
        else
            log "killing wedged scanner PID $scanner_pid"
            kill "$scanner_pid" 2>/dev/null || true
            sleep 2
            # Force-kill if still alive after SIGTERM grace period.
            if kill -0 "$scanner_pid" 2>/dev/null; then
                kill -9 "$scanner_pid" 2>/dev/null || true
            fi
        fi
    fi
fi

# On macOS, launchd KeepAlive=true will restart the scanner automatically
# once the process exits. On Linux (cron-based), invoke the scanner directly
# in background so the watchdog job itself returns quickly.
if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

if command -v launchctl >/dev/null 2>&1; then
    # macOS — launchd restart via kickstart (reload service).
    log "kickstarting launchd service $LAUNCHD_LABEL"
    launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null \
        || launchctl start "$LAUNCHD_LABEL" 2>/dev/null \
        || log "WARN: launchctl restart failed — KeepAlive should handle it"
else
    # Linux — start scanner in background; systemd / cron KeepAlive handles it.
    log "starting scanner directly (non-macOS)"
    nohup "$LOOP_ROOT/scanner/scanner.sh" >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
fi

log "restart triggered"
