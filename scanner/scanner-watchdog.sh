#!/usr/bin/env bash
# scanner-watchdog.sh — restart the Loop scanner if its heartbeat file is stale.
#
# scanner.sh writes ${LOOP_LOG_DIR}/scanner-heartbeat on every tick. This
# watchdog reads the file's mtime; if older than LOOP_WATCHDOG_STALE_SECONDS
# (default 600 = 2× the default 5-min poll interval), it kills the stale
# process and triggers a restart.
#
# Designed to run every 5 min via launchd (macOS) or cron (Linux).
#
# Flags:
#   --dry-run   print what would be done without acting
#   --once      single check (default; alias for clarity)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_SECONDS="${LOOP_WATCHDOG_STALE_SECONDS:-600}"
SCANNER_LOCK="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

log "check (stale_threshold=${STALE_SECONDS}s dry_run=${DRY_RUN})"

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat absent — scanner may not have started yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s"

if [ "$age" -lt "$STALE_SECONDS" ]; then
    log "scanner alive (heartbeat age=${age}s < ${STALE_SECONDS}s)"
    exit 0
fi

log "WARN: heartbeat stale (${age}s >= ${STALE_SECONDS}s) — restarting scanner"

scanner_pid=""
if [ -f "$SCANNER_LOCK" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill PID ${scanner_pid:-unknown} and trigger restart"
    exit 0
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing stale scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    sleep 2
fi

if [ "$(uname -s)" = "Darwin" ]; then
    local_uid=$(id -u)
    log "kickstart via launchctl (uid=$local_uid)"
    launchctl kickstart -k "gui/${local_uid}/com.user.loop-scanner" 2>/dev/null \
        || log "WARN: launchctl kickstart failed — launchd KeepAlive will restart on next cycle"
else
    log "Linux: scanner killed; cron will restart it on the next */5 interval"
fi
