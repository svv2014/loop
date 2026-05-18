#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if it has been silent for too long.
#
# Reads the heartbeat file written by scanner.sh on every tick. If the
# heartbeat mtime is older than STALE_THRESHOLD seconds, kills the scanner
# process (by PID from its lock file) so launchd (macOS) or cron (Linux)
# restarts it automatically.
#
# Run every 5 minutes via launchd StartInterval or crontab */5.
#
# Configuration (env vars, sourced from loop.env):
#   LOOP_SCANNER_WATCHDOG_THRESHOLD — stale threshold in seconds
#                                     (default: 2 × LOOP_SCANNER_INTERVAL = 600s)
#   LOOP_SCANNER_INTERVAL           — scanner poll interval (default: 300s)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# If the heartbeat file has never been written, the scanner may not have
# completed its first tick yet — give it the benefit of the doubt.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "no heartbeat file yet — scanner may not have started; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo "$now")
age=$(( now - mtime ))

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s — scanner OK"
    exit 0
fi

log "STALE: heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s — initiating restart"

# Kill the scanner by its lock-file PID. The lock's EXIT trap removes the
# file on clean exit, so on SIGTERM launchd will restart it promptly.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "sending SIGTERM to scanner PID $pid"
        kill "$pid" 2>/dev/null || true
        # Give it 5 s to exit cleanly before forcing.
        local_deadline=$(( now + 5 ))
        while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$local_deadline" ]; do
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            log "scanner PID $pid still alive — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$LOCK_FILE"
    else
        log "lock file present but PID ${pid:-<empty>} is not alive — removing stale lock"
        rm -f "$LOCK_FILE"
    fi
else
    log "no lock file found — scanner is not running"
fi

# On macOS, ask launchd to restart it immediately (KeepAlive would do so on
# its own after ThrottleInterval, but kickstart triggers it without the delay).
if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
        && log "launchctl kickstart sent — scanner will restart momentarily" \
        || log "WARN: launchctl kickstart failed (launchd will restart via KeepAlive)"
fi

log "done"
