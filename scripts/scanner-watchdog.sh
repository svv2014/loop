#!/usr/bin/env bash
# scanner-watchdog.sh — restart the Loop scanner when its heartbeat goes stale.
#
# scanner.sh writes ${LOOP_LOG_DIR}/scanner-heartbeat at the start of every tick.
# If that file is missing or its mtime exceeds STALE_THRESHOLD_SECONDS the scanner
# is considered wedged: its PID is killed and launchd/cron auto-restarts it.
#
# Designed to run every 5 minutes via launchd (macOS) or cron (Linux).
# Install via: ./install.sh --bootstrap  (adds a launchd plist / crontab entry)
#
# Flags:
#   --dry-run   report status without killing or restarting
#
# Env overrides:
#   STALE_THRESHOLD_SECONDS   — max heartbeat age before restart (default 900 = 15 min)
#   LOOP_SCANNER_LAUNCHD_LABEL — launchd service label (default com.user.loop-scanner)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

STALE_THRESHOLD="${STALE_THRESHOLD_SECONDS:-900}"
HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="${LOOP_LOCK_DIR:-/tmp/loop-locks}/../loop-scanner.lock"
# The scanner lock lives at /tmp/loop-scanner.lock (hard-coded in scanner.sh).
SCANNER_LOCK="/tmp/loop-scanner.lock"
LAUNCHD_LABEL="${LOOP_SCANNER_LAUNCHD_LABEL:-com.user.loop-scanner}"
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

# _file_age_seconds <path>
# Prints age in seconds (now - mtime), or 999999 if the file is missing.
_file_age_seconds() {
    local f="$1"
    [ -f "$f" ] || { echo "999999"; return 0; }
    local mtime now
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

heartbeat_age=$(_file_age_seconds "$HEARTBEAT_FILE")
log "heartbeat_file=${HEARTBEAT_FILE} age=${heartbeat_age}s threshold=${STALE_THRESHOLD}s dry_run=${DRY_RUN}"

if [ "$heartbeat_age" -lt "$STALE_THRESHOLD" ]; then
    log "scanner healthy — no action needed"
    exit 0
fi

log "WARN: scanner heartbeat stale (${heartbeat_age}s > ${STALE_THRESHOLD}s) — restarting"

if $DRY_RUN; then
    log "DRY-RUN: would kill scanner PID from $SCANNER_LOCK and kickstart $LAUNCHD_LABEL"
    exit 0
fi

# Kill the wedged scanner process so launchd/cron can restart a clean instance.
if [ -f "$SCANNER_LOCK" ]; then
    local_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || echo "")
    if [ -n "$local_pid" ] && kill -0 "$local_pid" 2>/dev/null; then
        log "killing wedged scanner PID $local_pid"
        kill "$local_pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$SCANNER_LOCK"
fi

# On macOS, kick launchd to restart the scanner immediately (KeepAlive=true means
# launchd would restart it anyway on next check-in, but kickstart is instant).
# On Linux the scanner runs via cron --once or a systemd unit that auto-restarts.
if command -v launchctl >/dev/null 2>&1; then
    log "kickstarting launchd service $LAUNCHD_LABEL"
    launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null \
        || log "WARN: launchctl kickstart failed — service will restart on next launchd check-in"
else
    log "launchctl unavailable — scanner will restart on next cron/systemd cycle"
fi
