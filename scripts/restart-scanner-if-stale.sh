#!/usr/bin/env bash
# restart-scanner-if-stale.sh — kill and restart the scanner if its heartbeat is stale.
#
# Checks ${LOOP_LOG_DIR}/scanner-heartbeat. If the file's mtime is older than
# LOOP_SCANNER_STALE_THRESHOLD seconds (default: 900 / 15 min), the scanner is
# considered wedged. The lock file at /tmp/loop-scanner.lock is read for the PID;
# if alive it is sent SIGTERM (then SIGKILL if needed) so launchd (KeepAlive=true
# on com.user.loop-scanner) auto-restarts the process.
#
# Falls back to checking the scanner log mtime when the heartbeat file is absent.
#
# Designed to run every 5 minutes via launchd / cron.
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOG="${LOOP_LOG_DIR}/loop-scanner.log"
LOCK_FILE="/tmp/loop-scanner.lock"
WATCHDOG_LOG="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"
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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$WATCHDOG_LOG"; }

# _file_age_seconds <path>
# Prints seconds since the file was last modified; prints -1 if absent.
_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo -1; return; }
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Determine liveness from the heartbeat file; fall back to the scanner log.
probe_file="$HEARTBEAT_FILE"
probe_label="heartbeat"
if [ ! -f "$HEARTBEAT_FILE" ]; then
    probe_file="$SCANNER_LOG"
    probe_label="scanner-log"
fi

age=$(_file_age_seconds "$probe_file")

if [ "$age" -lt 0 ]; then
    log "${probe_label} file missing — scanner may not have started yet; skipping"
    exit 0
fi

log "${probe_label} age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "STALE: ${probe_label} is ${age}s old (threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    log "DRY-RUN: would kill scanner PID ${scanner_pid:-<unknown>} and trigger launchd restart"
    exit 0
fi

if [ ! -f "$LOCK_FILE" ]; then
    log "no lock file — scanner not running; launchd will restart it automatically"
    exit 0
fi

scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$scanner_pid" ]; then
    log "lock file is empty — removing and allowing launchd to restart"
    rm -f "$LOCK_FILE"
    exit 0
fi

if ! kill -0 "$scanner_pid" 2>/dev/null; then
    log "scanner PID $scanner_pid is already dead — removing stale lock; launchd will restart"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "killing wedged scanner PID $scanner_pid (SIGTERM) — launchd KeepAlive will restart"
kill "$scanner_pid" || true
sleep 2
if kill -0 "$scanner_pid" 2>/dev/null; then
    log "WARN: PID $scanner_pid still alive after SIGTERM — sending SIGKILL"
    kill -9 "$scanner_pid" || true
fi

# Belt-and-suspenders: kickstart via launchctl for macOS environments.
if command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        && log "launchctl kickstart succeeded" \
        || log "launchctl kickstart not available or failed (expected on Linux/cron installs)"
fi

log "done — scanner will be restarted by launchd / cron"
