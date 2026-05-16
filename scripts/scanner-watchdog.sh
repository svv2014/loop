#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file goes stale.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# On macOS the scanner is a KeepAlive launchd agent — killing its PID causes
# launchd to auto-restart it. On Linux the scanner runs via cron (--once),
# so stale heartbeat = something wedged in the current invocation; killing it
# lets cron start a fresh one on the next tick.
#
# Environment (read from loop.env if present):
#   LOOP_SCANNER_INTERVAL   — expected tick interval in seconds (default 300)
#   LOOP_SCANNER_STALE_MULT — heartbeat age multiplier before declaring stale (default 2)
#   LOOP_LOG_DIR            — where scanner-heartbeat lives
#
# Flags:
#   --dry-run   report staleness without killing the scanner

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
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_MULT="${LOOP_SCANNER_STALE_MULT:-2}"
STALE_THRESHOLD=$(( POLL_INTERVAL * STALE_MULT ))
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log "tick (stale-threshold=${STALE_THRESHOLD}s, dry-run=${DRY_RUN})"

# --- check heartbeat freshness ---
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "INFO: heartbeat file not found — scanner may not have started yet; skipping"
    exit 0
fi

heartbeat_age=$(( $(date +%s) - $(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "OK: heartbeat age=${heartbeat_age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "WARN: heartbeat stale (age=${heartbeat_age}s >= threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let launchd/cron restart it"
    exit 0
fi

# --- kill the wedged scanner ---
scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    sleep 2
    # Force if still alive
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "scanner still alive after SIGTERM — sending SIGKILL"
        kill -9 "$scanner_pid" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE"
    log "scanner killed; launchd/cron will restart on next interval"
else
    log "WARN: no live scanner PID found (lock=${LOCK_FILE}, pid=${scanner_pid:-none}) — removing stale heartbeat"
    rm -f "$HEARTBEAT_FILE"
fi
