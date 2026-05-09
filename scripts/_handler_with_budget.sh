#!/usr/bin/env bash
# _handler_with_budget.sh — internal wrapper that runs a handler and records
# its elapsed wall-clock time toward the daily budget counter.
#
# Usage (set by scanner's dispatch_direct):
#   _handler_with_budget.sh <handler_script> [args...]
#
# Records elapsed seconds (regardless of handler exit code) into:
#   ${LOOP_LOG_DIR}/budget/YYYYMMDD.counter
#
# Counter file is plain text (one integer). Read by scanner before each
# scan_project iteration; if >= LOOP_DAILY_HANDLER_BUDGET_SECONDS, scanner
# skips emitting new work for the rest of the day.
#
# A new day rolls over automatically because the filename includes the date.
# The budget directory is under LOOP_LOG_DIR so it persists across OS reboots.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <handler_script> [args...]" >&2
    exit 2
fi

HANDLER="$1"
shift

_budget_dir()     { printf '%s/budget' "${LOOP_LOG_DIR:?LOOP_LOG_DIR must be set}"; }
_budget_counter_path() { printf '%s/%s.counter' "$(_budget_dir)" "$(date +%Y%m%d)"; }
_budget_lock_path()    { printf '%s/%s.counter.lock' "$(_budget_dir)" "$(date +%Y%m%d)"; }
mkdir -p "$(_budget_dir)"

START_TS=$(date +%s)
COUNTER_FILE="$(_budget_counter_path)"

# Run the handler. Don't fail the wrapper just because the handler did —
# we still need to record its time.
"$HANDLER" "$@"
HANDLER_RC=$?

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# Atomic increment — flock keeps concurrent handlers from racing.
# macOS doesn't ship flock; fall back to a coarser lock-file dance.
if command -v flock >/dev/null 2>&1; then
    (
        flock -x 9
        prev=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
        echo $(( prev + ELAPSED )) > "$COUNTER_FILE"
    ) 9>>"$(_budget_lock_path)"
else
    # Best-effort: a brief lockfile retry. Concurrent handlers may still
    # race here; budget is a soft cap, so undercounting by a few seconds
    # is tolerable.
    LOCKFILE="$(_budget_lock_path)"
    for _ in 1 2 3 4 5; do
        if mkdir "$LOCKFILE" 2>/dev/null; then
            prev=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
            echo $(( prev + ELAPSED )) > "$COUNTER_FILE"
            rmdir "$LOCKFILE"
            break
        fi
        sleep 0.2
    done
fi

exit "$HANDLER_RC"
