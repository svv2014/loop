#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat goes stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (updated every tick by scanner.sh).
# If the file's mtime is older than STALE_THRESHOLD_SECONDS (default: 2×poll
# interval = 600s), kills the scanner PID from /tmp/loop-scanner.lock and
# triggers a restart via launchctl kickstart (macOS) or by directly spawning
# scanner.sh (Linux).
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# On macOS, KeepAlive=true on the scanner plist means killing the scanner PID
# is sufficient — launchd restarts it automatically. The kickstart call is a
# belt-and-braces fallback in case KeepAlive stalls.
#
# Usage:
#   scanner-watchdog.sh          # check once; exit 0 always
#   scanner-watchdog.sh --dry-run  # print what would happen, don't act

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
STALE_THRESHOLD_SECONDS="${LOOP_WATCHDOG_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner-watchdog] $*"; }

# _file_age_seconds <path>
# Print the number of seconds since the file was last modified.
# Returns a large number if the file does not exist (treat as maximally stale).
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "999999"
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid
# Read the PID from the lock file. Print nothing if unavailable.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 0
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    printf '%s' "${pid:-}"
}

# _kill_scanner <pid>
# Send SIGTERM to the scanner process. Returns 0 on success.
_kill_scanner() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -TERM "$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || return 1
}

# _restart_scanner_macos
# Use launchctl to restart the scanner service. KeepAlive handles the restart
# automatically after kill; this is the explicit belt-and-braces path.
_restart_scanner_macos() {
    local plist_path="$HOME/Library/LaunchAgents/com.user.loop-scanner.plist"
    if [ -f "$plist_path" ]; then
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || launchctl stop "com.user.loop-scanner" 2>/dev/null \
            || true
        log "launchctl kickstart issued for com.user.loop-scanner"
    else
        log "WARN: launchd plist not found at $plist_path — scanner will rely on KeepAlive restart"
    fi
}

# _restart_scanner_linux
# Spawn a background scanner --once. On Linux without launchd, the watchdog
# becomes responsible for firing a single sweep; a systemd unit or cron owns
# the continuous loop.
_restart_scanner_linux() {
    nohup "$LOOP_ROOT/scanner/scanner.sh" --once \
        >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
    log "spawned scanner.sh --once (PID $!)"
}

age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat age=${age}s threshold=${STALE_THRESHOLD_SECONDS}s heartbeat=${HEARTBEAT_FILE}"

if [ "$age" -lt "$STALE_THRESHOLD_SECONDS" ]; then
    log "scanner healthy — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${STALE_THRESHOLD_SECONDS}s) — restarting"

scanner_pid=$(_scanner_pid)
if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    if $DRY_RUN; then
        log "DRY-RUN: would kill scanner PID $scanner_pid"
    else
        log "killing scanner PID $scanner_pid"
        _kill_scanner "$scanner_pid" || log "WARN: kill $scanner_pid failed (may have already exited)"
        rm -f "$LOCK_FILE"
    fi
else
    log "scanner PID not running (lock: ${scanner_pid:-none}) — triggering restart anyway"
    rm -f "$LOCK_FILE"
fi

if $DRY_RUN; then
    log "DRY-RUN: would restart scanner"
    exit 0
fi

case "$(uname -s)" in
    Darwin) _restart_scanner_macos ;;
    *)      _restart_scanner_linux ;;
esac
