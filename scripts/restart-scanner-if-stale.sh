#!/usr/bin/env bash
# restart-scanner-if-stale.sh — Watchdog for the Loop scanner process.
#
# Checks the mtime of ${LOOP_LOG_DIR}/scanner-heartbeat. If the file is older
# than STALE_THRESHOLD seconds (default 900 = 15 min, which is 3× the default
# 300 s poll interval) the scanner is considered silently wedged and is
# restarted via launchctl kickstart (macOS) or kill + respawn (Linux).
#
# Intended to be run every 5 minutes by a launchd agent (macOS) or cron (Linux).
# The launchd plist template is: templates/launchd/com.user.loop-scanner-watchdog.plist.template
#
# Usage:
#   restart-scanner-if-stale.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
STALE_THRESHOLD="${LOOP_WATCHDOG_STALE_THRESHOLD:-900}"
SCANNER_LAUNCHD_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"

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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $*"; }

# _file_age_seconds <path>
# Returns the number of seconds since the file was last modified.
# Falls back to a very large number (heartbeat counts as infinitely stale)
# if the file does not exist or stat fails.
_file_age_seconds() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo 999999
        return 0
    fi
    local mtime now
    mtime=$(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

# _restart_scanner_macos — kick the launchd agent.
_restart_scanner_macos() {
    local label="$SCANNER_LAUNCHD_LABEL"
    log "restarting scanner via launchctl kickstart: $label"
    if $DRY_RUN; then
        log "DRY-RUN: launchctl kickstart -k gui/$(id -u)/${label}"
        return 0
    fi
    if launchctl kickstart -k "gui/$(id -u)/${label}" 2>/dev/null; then
        log "launchctl kickstart succeeded"
    else
        log "WARN: launchctl kickstart failed; trying launchctl stop/start"
        launchctl stop  "$label" 2>/dev/null || true
        launchctl start "$label" 2>/dev/null || true
    fi
}

# _restart_scanner_linux — kill the running scanner and let systemd / cron respawn it,
# or start the scanner script directly as a background process if no service manager.
_restart_scanner_linux() {
    log "restarting scanner on Linux"
    if $DRY_RUN; then
        log "DRY-RUN: would kill scanner and respawn"
        return 0
    fi
    # Attempt systemctl first (systemd environments).
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet loop-scanner 2>/dev/null; then
        log "restarting via systemctl"
        systemctl restart loop-scanner
        return 0
    fi
    # Fallback: kill the scanner process by lock-file PID, then respawn.
    local lock_file="/tmp/loop-scanner.lock"
    if [ -f "$lock_file" ]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "killing wedged scanner PID $pid"
            kill "$pid" 2>/dev/null || true
            sleep 2
        fi
    fi
    log "spawning scanner in background"
    nohup "$LOOP_ROOT/scanner/scanner.sh" \
        >> "${LOOP_LOG_DIR}/loop-scanner.log" 2>&1 &
    log "scanner spawned as PID $!"
}

main() {
    local age
    age=$(_file_age_seconds "$HEARTBEAT_FILE")
    log "heartbeat age=${age}s threshold=${STALE_THRESHOLD}s file=${HEARTBEAT_FILE}"

    if [ "$age" -lt "$STALE_THRESHOLD" ]; then
        log "scanner is healthy (heartbeat ${age}s old)"
        exit 0
    fi

    log "ALERT: scanner heartbeat is stale (${age}s > ${STALE_THRESHOLD}s) — restarting"

    case "$(uname -s)" in
        Darwin) _restart_scanner_macos ;;
        *)      _restart_scanner_linux ;;
    esac

    log "restart triggered"
}

main "$@"
