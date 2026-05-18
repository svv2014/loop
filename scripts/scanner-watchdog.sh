#!/usr/bin/env bash
# scanner-watchdog.sh — restart the scanner if its heartbeat is stale.
#
# Reads ${LOOP_LOG_DIR}/scanner-heartbeat (written by scanner.sh every tick).
# If the file's mtime is older than LOOP_SCANNER_WATCHDOG_THRESHOLD (default:
# 2 × LOOP_SCANNER_INTERVAL, floor 900s / 15 min), the scanner is considered
# wedged: its PID is killed so launchd (KeepAlive=true) restarts it.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
#
# Usage:
#   scanner-watchdog.sh           # run one liveness check
#   scanner-watchdog.sh --dry-run # report, don't kill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
_default_threshold=$(( POLL_INTERVAL * 2 ))
[ "$_default_threshold" -lt 900 ] && _default_threshold=900
THRESHOLD="${LOOP_SCANNER_WATCHDOG_THRESHOLD:-${_default_threshold}}"

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

# If the heartbeat file has never been written (fresh install, first boot),
# skip — the scanner may still be in its first tick.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "heartbeat file not found (${HEARTBEAT_FILE}) — scanner may not have ticked yet; skipping"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
age=$(( now - mtime ))

log "heartbeat age=${age}s threshold=${THRESHOLD}s"

if [ "$age" -lt "$THRESHOLD" ]; then
    log "scanner is alive (heartbeat ${age}s ago)"
    exit 0
fi

log "WARN: scanner heartbeat stale (${age}s > ${THRESHOLD}s) — triggering restart"

scanner_pid=""
if [ -f "$LOCK_FILE" ]; then
    scanner_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
fi

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID=${scanner_pid:-unknown} and trigger restart"
    exit 0
fi

# Kill the wedged scanner so launchd (KeepAlive) restarts it.
if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid"
    kill "$scanner_pid" 2>/dev/null || true
    for _ in 1 2 3; do
        sleep 1
        kill -0 "$scanner_pid" 2>/dev/null || break
    done
    if kill -0 "$scanner_pid" 2>/dev/null; then
        log "scanner did not exit after SIGTERM — sending SIGKILL to $scanner_pid"
        kill -9 "$scanner_pid" 2>/dev/null || true
    fi
else
    log "scanner PID ${scanner_pid:-unknown} is not alive — stale lock; no kill needed"
fi

# On macOS, prod launchd to restart immediately (KeepAlive handles it, but
# kickstart avoids the ThrottleInterval delay).
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list 2>/dev/null | grep -q "com.user.loop-scanner"; then
        log "launchctl kickstart com.user.loop-scanner"
        launchctl kickstart -k "gui/$(id -u)/com.user.loop-scanner" 2>/dev/null \
            || log "WARN: launchctl kickstart failed — launchd will restart via KeepAlive"
    fi
fi

log "restart triggered"
