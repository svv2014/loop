#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is absent or its mtime
# is older than LOOP_SCANNER_STALE_THRESHOLD seconds (default: 2 × POLL_INTERVAL
# = 600s), the scanner is considered wedged. Kills the PID recorded in
# LOOP_SCANNER_LOCK (default: /tmp/loop-scanner.lock); launchd (KeepAlive=true)
# or cron will restart scanner.sh automatically.
#
# Intended to run every 5 minutes via launchd StartInterval or cron.
#
# macOS install — see templates/launchd/com.user.loop-scanner-watchdog.plist.template
# Linux crontab:
#   */5 * * * * /path/to/loop/scanner/restart-scanner-if-stale.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="${LOOP_SCANNER_LOCK:-/tmp/loop-scanner.lock}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
WD_LOG="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "${WD_LOG}" >&2; }

# Portable mtime: macOS stat -f%m vs GNU stat -c%Y.
_file_age_seconds() {
    local f="$1"
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

if [ ! -f "${HEARTBEAT_FILE}" ]; then
    log "heartbeat file absent — scanner may not have started yet; skipping"
    exit 0
fi

age=$(_file_age_seconds "${HEARTBEAT_FILE}")

if [ "${age}" -lt "${STALE_THRESHOLD}" ]; then
    log "ok: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${age}s exceeds threshold=${STALE_THRESHOLD}s — restarting scanner"

if [ ! -f "${LOCK_FILE}" ]; then
    log "lock file ${LOCK_FILE} not found — launchd will restart scanner automatically"
    exit 0
fi

pid=$(cat "${LOCK_FILE}" 2>/dev/null || true)
if [ -z "${pid}" ]; then
    log "WARN: lock file empty — removing stale lock"
    rm -f "${LOCK_FILE}"
    exit 0
fi

if ! kill -0 "${pid}" 2>/dev/null; then
    log "WARN: PID ${pid} not alive — removing stale lock"
    rm -f "${LOCK_FILE}"
    exit 0
fi

log "killing wedged scanner PID ${pid}"
kill "${pid}" 2>/dev/null || true
# Allow the scanner EXIT trap to clean the lock before launchd restarts it.
sleep 2
log "done — launchd/cron will restart scanner.sh"
