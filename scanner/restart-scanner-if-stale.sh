#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is absent or its mtime
# is older than STALE_THRESHOLD_SECONDS (default: 2 × LOOP_SCANNER_INTERVAL,
# i.e. 600s), the scanner is considered wedged. The script then kills the PID
# recorded in /tmp/loop-scanner.lock; launchd (KeepAlive=true) or cron will
# restart it automatically.
#
# Intended to run every 5 minutes via launchd StartInterval or cron.
# Install on macOS:
#   cp templates/launchd/com.user.loop-scanner-watchdog.plist.template \
#      ~/Library/LaunchAgents/com.user.loop-scanner-watchdog.plist
#   # then edit __LOOP_ROOT__, __LOG_DIR__, __HOME__, __EXTRA_PATH__
#   launchctl load ~/Library/LaunchAgents/com.user.loop-scanner-watchdog.plist
#
# Install on Linux (add to crontab):
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
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner-watchdog.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*" | tee -a "$LOG_FILE" >&2; }

# Resolve mtime portably (macOS stat vs GNU stat).
_file_age_seconds() {
    local f="$1"
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Check heartbeat freshness.
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

# Kill the recorded scanner PID so launchd (KeepAlive) or cron restarts it.
if [ ! -f "${LOCK_FILE}" ]; then
    log "lock file ${LOCK_FILE} not found — nothing to kill (launchd will restart)"
    exit 0
fi

pid=$(cat "${LOCK_FILE}" 2>/dev/null || true)
if [ -z "${pid}" ]; then
    log "WARN: lock file empty — removing and exiting"
    rm -f "${LOCK_FILE}"
    exit 0
fi

if ! kill -0 "${pid}" 2>/dev/null; then
    log "WARN: PID ${pid} from lock file is not alive — removing stale lock"
    rm -f "${LOCK_FILE}"
    exit 0
fi

log "killing wedged scanner PID ${pid}"
kill "${pid}" 2>/dev/null || true
# Give launchd a moment; do not force-remove the lock — the scanner's EXIT
# trap handles that, and launchd needs to observe the exit before restarting.
sleep 2
log "done — launchd/cron will restart scanner.sh"
