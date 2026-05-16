#!/usr/bin/env bash
# scanner-watchdog.sh — Liveness watchdog for scanner.sh.
#
# Reads the heartbeat file written by scanner.sh on every tick.
# If the file is missing or stale (mtime older than LOOP_SCANNER_WATCHDOG_THRESHOLD
# seconds, default 2 × LOOP_SCANNER_INTERVAL), the scanner PID is killed so
# launchd (macOS) or cron (Linux) restarts it automatically.
#
# Usage:
#   scanner-watchdog.sh            # normal (run via launchd StartInterval or cron)
#   scanner-watchdog.sh --dry-run  # report status without killing

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

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
HB_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log "threshold=${THRESHOLD}s heartbeat=${HB_FILE}"

# Check heartbeat file age.
if [ ! -f "$HB_FILE" ]; then
    log "WARN: heartbeat file missing — scanner may never have started or is wedged"
    hb_age=$((THRESHOLD + 1))
else
    now=$(date +%s)
    hb_mtime=$(stat -f%m "$HB_FILE" 2>/dev/null || stat -c%Y "$HB_FILE" 2>/dev/null || echo 0)
    hb_age=$(( now - hb_mtime ))
    log "heartbeat age=${hb_age}s"
fi

if [ "$hb_age" -lt "$THRESHOLD" ]; then
    log "OK — scanner is alive (heartbeat ${hb_age}s < threshold ${THRESHOLD}s)"
    exit 0
fi

log "STALE: heartbeat is ${hb_age}s old (threshold ${THRESHOLD}s) — scanner appears wedged"

# Read the scanner PID from the lock file.
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    if [ -n "$scanner_pid" ]; then
        log "DRY-RUN: would kill scanner PID $scanner_pid"
    else
        log "DRY-RUN: no PID in lock file — launchd/cron would restart on next check"
    fi
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    sleep 2
    # SIGKILL if still alive.
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "SIGKILL scanner PID $scanner_pid"
        kill -9 "$scanner_pid" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE"
    log "scanner killed — launchd/cron will restart it"
else
    log "scanner PID not alive (pid='$scanner_pid') — removing stale lock if present"
    rm -f "$LOCK_FILE"
fi
