#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat file goes stale.
#
# Run every 5 min via launchd (macOS) or cron (Linux).
# If ${LOOP_LOG_DIR}/scanner-heartbeat has not been touched within
# LOOP_SCANNER_STALE_THRESHOLD seconds (default: 2 * LOOP_SCANNER_INTERVAL),
# the scanner is considered wedged and is restarted.
#
# macOS: restarts via `launchctl kickstart`; assumes the scanner is managed
#        under the label com.user.loop-scanner.
# Linux: kills the PID recorded in /tmp/loop-scanner.lock (launchd-equivalent
#        supervision or a simple restart-on-exit wrapper restarts it).
#
# Flags:
#   --dry-run   print what would happen; don't kill or restart
#   --once      single check (default; future loop mode reserved)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Allow 2× the poll interval before declaring the scanner wedged.
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

# Bail out if the heartbeat file has never been created — the scanner may not
# have started yet. Log at debug level and exit cleanly.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found (${HEARTBEAT_FILE}) — scanner may not have started yet; skipping"
    exit 0
fi

# Compute age of heartbeat file in seconds.
heartbeat_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
    || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
    || echo 0)
now=$(date +%s)
age=$(( now - heartbeat_mtime ))

log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner is healthy"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD}s) — triggering restart"

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

LOCK_FILE="/tmp/loop-scanner.lock"

if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS: restart via launchctl. KeepAlive=true in the plist means kickstart
    # will relaunch the job immediately after the old process is killed.
    LAUNCHD_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"
    if launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null; then
        log "restarted scanner via launchctl kickstart (label=${LAUNCHD_LABEL})"
    else
        # Fallback: kill the PID from the lock file.
        if [ -f "$LOCK_FILE" ]; then
            local_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
                kill "$local_pid" 2>/dev/null && log "killed scanner PID ${local_pid} (launchd will restart)"
            else
                log "WARN: launchctl kickstart failed and no live PID in lock file — manual restart may be needed"
            fi
        else
            log "WARN: launchctl kickstart failed and lock file absent — manual restart may be needed"
        fi
    fi
else
    # Linux: kill the PID from the lock file. A process supervisor (systemd,
    # runit, or a cron-based restart-on-exit wrapper) should restart the scanner.
    if [ -f "$LOCK_FILE" ]; then
        linux_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$linux_pid" ] && kill -0 "$linux_pid" 2>/dev/null; then
            kill "$linux_pid" 2>/dev/null && log "killed scanner PID ${linux_pid} — supervisor should restart"
        else
            log "WARN: no live scanner PID found in lock file — scanner may already be stopped"
        fi
    else
        log "WARN: lock file not found (${LOCK_FILE}) — scanner may not be running"
    fi
fi
