#!/usr/bin/env bash
# scanner-watchdog.sh — restart scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file is missing or older than STALE_THRESHOLD seconds, the scanner
# is considered wedged and is killed + restarted.
#
# Designed to run every 5 min via launchd (macOS) or cron (Linux).
#
# Flags:
#   --dry-run   print what would happen without killing/restarting anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale = 2× poll interval so one missed tick doesn't trigger a false restart.
STALE_THRESHOLD=$(( POLL_INTERVAL * 2 ))

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"

now=$(date +%s)

if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file missing (${HEARTBEAT_FILE}) — scanner may not have started yet"
    exit 0
fi

mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is alive — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat stale (age=${age}s > threshold=${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner now"
    exit 0
fi

# macOS: launchd manages the scanner via KeepAlive; kickstart -k kills the
# running instance and lets launchd relaunch it.
if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
    if launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null; then
        log "restarted via launchctl kickstart"
        exit 0
    fi
    log "launchctl kickstart failed — falling back to SIGTERM"
fi

# Linux / fallback: kill the running scanner PID so its supervisor (cron or
# systemd) relaunches it on the next scheduled run.
local_lock="/tmp/loop-scanner.lock"
if [ -f "$local_lock" ]; then
    old_pid=$(cat "$local_lock" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        log "sending SIGTERM to scanner PID ${old_pid}"
        kill -TERM "$old_pid" 2>/dev/null || true
    else
        log "lock file present but PID ${old_pid} is not running — removing stale lock"
        rm -f "$local_lock"
    fi
else
    log "no lock file found — scanner is not running; nothing to kill"
fi
