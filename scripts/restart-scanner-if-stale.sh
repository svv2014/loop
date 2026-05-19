#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Checks the scanner heartbeat file. If the file is older than
# LOOP_SCANNER_STALE_THRESHOLD seconds (default: 900 = 15 min, ~3x the
# default poll interval), the scanner is considered wedged and its PID is
# killed so launchd (KeepAlive=true) or systemd (Restart=always) restarts it.
#
# Run every 5 minutes via launchd or cron. See:
#   templates/launchd/com.user.loop-scanner-watchdog.plist.template
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]
#
# Environment (all optional):
#   LOOP_LOG_DIR                  base log directory (default: ~/.loop/logs)
#   LOOP_SCANNER_STALE_THRESHOLD  age in seconds before declaring scanner wedged
#                                 (default: 900)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-900}"
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

# Heartbeat file absent means the scanner has never ticked — nothing to kill.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file absent — scanner has not ticked yet, nothing to do"
    exit 0
fi

heartbeat_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
now=$(date +%s)
age=$(( now - heartbeat_mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner appears wedged (heartbeat age=${age}s > ${STALE_THRESHOLD}s)"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if [ -z "$scanner_pid" ]; then
    log "no lock file or empty PID — scanner may have already exited"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "PID $scanner_pid is no longer alive — supervisor will restart on its own"
    exit 0
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill wedged scanner PID $scanner_pid"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid — supervisor will restart it"
kill "$scanner_pid" || true
