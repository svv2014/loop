#!/usr/bin/env bash
# restart-scanner-if-stale.sh — scanner liveness watchdog.
#
# Checks the scanner heartbeat file written at the top of every scan tick.
# If the file is missing or older than STALE_THRESHOLD_SECONDS, the scanner
# is considered wedged and is restarted:
#   - macOS (launchd): kills the PID from the lock file; launchd KeepAlive
#     restarts the process automatically.
#   - Linux (cron): same kill approach; cron's next invocation restarts it.
#
# Run every 5 minutes via launchd or cron. See install.sh bootstrap and
# templates/launchd/com.user.loop-scanner-watchdog.plist.template.
#
# Flags:
#   --dry-run   check and log, but don't kill the scanner
#   --help      show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
SCANNER_LOCK="/tmp/loop-scanner.lock"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
# Stale threshold: 2× poll interval (default 600s). Gives a full extra cycle
# before declaring wedge, avoiding false-positives on slow gh calls.
STALE_THRESHOLD="${LOOP_SCANNER_STALE_THRESHOLD:-$(( POLL_INTERVAL * 2 ))}"

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

now=$(date +%s)

# Check heartbeat file existence and age.
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "WARN: heartbeat file missing: $HEARTBEAT_FILE"
    stale=true
    age="(file absent)"
else
    mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo 0)
    age=$(( now - mtime ))
    if [ "$age" -gt "$STALE_THRESHOLD" ]; then
        stale=true
        log "WARN: heartbeat stale: age=${age}s threshold=${STALE_THRESHOLD}s"
    else
        stale=false
        log "OK: heartbeat age=${age}s threshold=${STALE_THRESHOLD}s"
    fi
fi

if [ "$stale" = false ]; then
    exit 0
fi

# Watchdog action: kill the wedged scanner; launchd/cron restarts it.
if $DRY_RUN; then
    log "DRY-RUN: would kill scanner (age=$age)"
    exit 0
fi

scanner_pid=""
if [ -f "$SCANNER_LOCK" ]; then
    scanner_pid=$(cat "$SCANNER_LOCK" 2>/dev/null || true)
fi

if [ -n "$scanner_pid" ] && kill -0 "$scanner_pid" 2>/dev/null; then
    log "killing wedged scanner PID $scanner_pid (age=$age)"
    kill "$scanner_pid" 2>/dev/null || true
    # Remove lock so the restarted scanner can acquire it immediately.
    rm -f "$SCANNER_LOCK"
    log "scanner killed — launchd/cron will restart it"
else
    log "scanner lock absent or PID dead (age=$age) — removing stale lock if present"
    rm -f "$SCANNER_LOCK"
fi
