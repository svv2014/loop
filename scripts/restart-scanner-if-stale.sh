#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the heartbeat file is older than STALE_THRESHOLD_SECONDS the scanner is
# considered wedged: kills the PID recorded in the lock file and, on macOS,
# asks launchd to restart the service. On Linux the process is simply killed so
# the host cron/systemd supervisor can restart it.
#
# Intended schedule: every 5 minutes (StartInterval 300 in launchd, or
# */5 * * * * in cron).
#
# Usage: restart-scanner-if-stale.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
        *) echo "Unknown flag: $_arg" >&2; exit 2 ;;
    esac
done

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2× poll interval (default 10 min).
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# Age of a file in seconds; returns a very large number if the file is absent.
_file_age() {
    local f="$1"
    [ -f "$f" ] || { echo 999999; return 0; }
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

hb_age=$(_file_age "$HEARTBEAT_FILE")

if [ "$hb_age" -lt "$STALE_THRESHOLD" ]; then
    log "OK: heartbeat age=${hb_age}s < threshold=${STALE_THRESHOLD}s"
    exit 0
fi

log "STALE: heartbeat age=${hb_age}s >= threshold=${STALE_THRESHOLD}s — restarting scanner"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and trigger restart"
    exit 0
fi

# Kill the scanner PID recorded in the lock file (if alive).
if [ -f "$LOCK_FILE" ]; then
    _lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
        log "killing wedged scanner PID $_lock_pid"
        kill "$_lock_pid" 2>/dev/null || true
        sleep 2
        # Force-kill if still alive after grace period.
        if kill -0 "$_lock_pid" 2>/dev/null; then
            kill -9 "$_lock_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$LOCK_FILE"
fi

# On macOS, ask launchd to restart the scanner service (KeepAlive=true ensures
# it comes back, but kickstart is faster than waiting for the implicit restart).
if command -v launchctl >/dev/null 2>&1; then
    _label="com.user.loop-scanner"
    if launchctl list "$_label" >/dev/null 2>&1; then
        log "launchctl kickstart gui/$(id -u)/$_label"
        launchctl kickstart "gui/$(id -u)/$_label" 2>/dev/null \
            || log "WARN: launchctl kickstart failed (launchd will auto-restart via KeepAlive)"
    fi
fi

log "watchdog done"
