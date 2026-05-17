#!/usr/bin/env bash
# scanner-watchdog.sh — restart a wedged scanner process.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh on every tick).
# If the file is absent or its mtime is older than STALE_THRESHOLD_SECONDS (default:
# 2 × LOOP_SCANNER_INTERVAL, i.e. 10 min at default settings), the scanner is
# considered wedged and is killed; launchd (macOS) or cron (Linux) restarts it.
#
# Usage:
#   scanner-watchdog.sh          # one-shot check (designed for launchd StartInterval / cron)
#   scanner-watchdog.sh --dry-run  # print verdict, don't kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Default stale threshold: 2× poll interval so one slow tick doesn't trigger a restart.
STALE_THRESHOLD="${LOOP_SCANNER_WATCHDOG_STALE_SECONDS:-$(( POLL_INTERVAL * 2 ))}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
LOCK_FILE="/tmp/loop-scanner.lock"
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

# _heartbeat_age_seconds — prints elapsed seconds since heartbeat was last written.
# Returns 1 (and prints nothing) if the file does not exist.
_heartbeat_age_seconds() {
    [ -f "$HEARTBEAT_FILE" ] || return 1
    local mtime now
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || return 1)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _scanner_pid — read PID from lock file if the process is still alive.
# Prints the PID or prints nothing.
_scanner_pid() {
    [ -f "$LOCK_FILE" ] || return 0
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null && echo "$pid" || true
}

main() {
    local age pid verdict="ok"

    if ! age=$(_heartbeat_age_seconds); then
        # No heartbeat file yet — scanner may not have run its first tick.
        # Only flag if the lock file exists (scanner is running but never wrote heartbeat).
        pid=$(_scanner_pid)
        if [ -n "$pid" ]; then
            log "WARN: scanner PID $pid running but no heartbeat file found — may be pre-first-tick"
        else
            log "heartbeat file absent and no scanner lock — nothing to watch"
        fi
        return 0
    fi

    log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"

    if [ "$age" -ge "$STALE_THRESHOLD" ]; then
        verdict="stale"
        pid=$(_scanner_pid)
        if [ -n "$pid" ]; then
            if $DRY_RUN; then
                log "DRY-RUN: would kill wedged scanner PID $pid (heartbeat age=${age}s)"
            else
                log "WARN: scanner wedged (heartbeat age=${age}s >= threshold=${STALE_THRESHOLD}s) — killing PID $pid"
                kill "$pid" 2>/dev/null || log "WARN: kill $pid failed (already gone?)"
                log "scanner killed — launchd/cron will restart it"
            fi
        else
            if $DRY_RUN; then
                log "DRY-RUN: stale heartbeat (age=${age}s) but no live scanner PID found"
            else
                log "WARN: stale heartbeat (age=${age}s) but no live scanner PID found — scanner may have already exited"
            fi
        fi
    fi

    log "verdict=${verdict}"
}

main
