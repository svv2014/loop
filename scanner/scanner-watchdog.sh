#!/usr/bin/env bash
# scanner-watchdog.sh — detect and restart a wedged scanner process.
#
# Runs every ~5 min via launchd (StartInterval) or cron. Checks whether the
# scanner heartbeat file is stale — older than 2 × LOOP_SCANNER_INTERVAL
# (default: 600 s). If stale AND the scanner PID from the lock file is alive,
# sends SIGTERM so launchd KeepAlive restarts it.
#
# In Linux cron --once mode each scanner invocation is already a fresh
# process, so this watchdog serves mainly as a staleness alarm there.
#
# Flags:
#   --dry-run   report stale state without killing

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
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

log "tick (stale-threshold=${STALE_THRESHOLD}s dry=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file — scanner not yet started or pre-heartbeat version running"
    exit 0
fi

heartbeat_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
heartbeat_age=$(( $(date +%s) - heartbeat_mtime ))
log "heartbeat age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy"
    exit 0
fi

log "WARN: heartbeat stale (${heartbeat_age}s >= ${STALE_THRESHOLD}s) — scanner may be wedged"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -z "$scanner_pid" ]; then
    log "no PID in lock file — scanner not running; launchd/cron will start it"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is not alive — lock is stale; restart expected on next launchd/cron tick"
    exit 0
fi

if $DRY_RUN; then
    log "DRY: would SIGTERM scanner PID $scanner_pid"
    exit 0
fi

log "sending SIGTERM to wedged scanner PID $scanner_pid"
kill -TERM "$scanner_pid" 2>/dev/null || true
log "done — launchd KeepAlive will restart the scanner"
