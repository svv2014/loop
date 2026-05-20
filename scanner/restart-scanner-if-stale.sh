#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written every tick by scanner.sh).
# If the file's mtime is older than STALE_THRESHOLD_SECONDS, the scanner is
# considered silently wedged: kill it and let launchd/cron restart it.
#
# Designed to run every 5 minutes via launchd StartInterval or cron.
# Does nothing on --dry-run (print decision without acting).
#
# Usage:
#   restart-scanner-if-stale.sh
#   restart-scanner-if-stale.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
# Default: 2 × poll interval (2 × 300s = 600s). Override via env var.
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"
LOCK_FILE="/tmp/loop-scanner.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# age_seconds <file>  — portable mtime age in seconds (macOS + Linux).
age_seconds() {
    local file="$1"
    local mtime
    mtime=$(stat -f%m "$file" 2>/dev/null) \
        || mtime=$(stat -c%Y "$file" 2>/dev/null) \
        || { echo 0; return 1; }
    echo $(( $(date +%s) - mtime ))
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file missing — scanner may not have started yet; skipping"
    exit 0
fi

age=$(age_seconds "$HEARTBEAT_FILE") || age=0

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy (heartbeat age=${age}s < threshold=${STALE_THRESHOLD}s)"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s >= threshold=${STALE_THRESHOLD}s)"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner and let launchd/cron restart it"
    exit 0
fi

# Kill all processes whose lock file PID is alive.
if [ -f "$LOCK_FILE" ]; then
    local_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        log "killing wedged scanner PID $local_pid"
        kill "$local_pid" 2>/dev/null || true
        sleep 2
        # Force-kill if it didn't respond.
        if kill -0 "$local_pid" 2>/dev/null; then
            log "SIGKILL PID $local_pid"
            kill -9 "$local_pid" 2>/dev/null || true
        fi
        rm -f "$LOCK_FILE"
    fi
fi

# On macOS, kick launchd to restart the scanner.
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list com.user.loop-scanner >/dev/null 2>&1; then
        log "kickstarting com.user.loop-scanner via launchd"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl start com.user.loop-scanner 2>/dev/null || true
        exit 0
    fi
fi

# On Linux (or when launchd is not managing the scanner), log only.
# The operator is responsible for configuring cron or systemd to restart.
log "scanner killed; restart it via your process manager (launchd/cron/systemd)"
