#!/usr/bin/env bash
# lib/handler_guard.sh — tick-time re-validation for handlers.
#
# When the scanner emits an event for a ticket, the ticket's state is
# captured at scan time. By the time the handler actually runs, an
# operator or another handler may have moved the ticket on (closed it,
# stripped the trigger label, applied `blocked`, etc.). Without a guard,
# the handler still acts on stale state — opens a duplicate PR, comments
# on a closed issue, etc.
#
# loop_handler_guard re-fetches the live label set just before the
# handler does its real work, and bails cleanly if the trigger label is
# no longer present or the ticket is already closed/merged.
#
# Usage from a handler:
#   if ! loop_handler_guard "$REPO" issue "$ISSUE_NUM" "$TRIGGER_LABEL"; then
#       exit 0
#   fi
#
# Returns:
#   0 — trigger label still present, ticket open: proceed
#   1 — guard tripped: caller should exit cleanly (NOT an error)
#
# Requires: gh CLI in PATH (used by both github + gitlab backends today
# for issue/pr label inspection).

# Idempotent source-guard.
[ -n "${_LOOP_HANDLER_GUARD_LOADED:-}" ] && return 0
_LOOP_HANDLER_GUARD_LOADED=1

# loop_handler_guard <repo> <kind> <number> <expected_label>
# kind: issue | pr
loop_handler_guard() {
    local repo="$1" kind="$2" num="$3" expected="$4"

    if [ -z "$repo" ] || [ -z "$kind" ] || [ -z "$num" ] || [ -z "$expected" ]; then
        echo "[handler-guard] ERROR: usage: loop_handler_guard <repo> <issue|pr> <num> <label>" >&2
        return 1
    fi

    local view labels state
    case "$kind" in
        issue)
            view=$(gh issue view "$num" --repo "$repo" --json state,labels 2>/dev/null) || {
                echo "[handler-guard] $kind #$num: gh view failed — assuming gone, bailing" >&2
                return 1
            }
            ;;
        pr)
            view=$(gh pr view "$num" --repo "$repo" --json state,labels 2>/dev/null) || {
                echo "[handler-guard] $kind #$num: gh view failed — assuming gone, bailing" >&2
                return 1
            }
            ;;
        *)
            echo "[handler-guard] ERROR: kind must be 'issue' or 'pr', got '$kind'" >&2
            return 1
            ;;
    esac

    state=$(echo "$view" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
    labels=$(echo "$view" | python3 -c "import json,sys; print(' '.join(l['name'] for l in json.load(sys.stdin).get('labels',[])))" 2>/dev/null)

    case "$state" in
        CLOSED|MERGED)
            echo "[handler-guard] $kind #$num: state=$state, skipping (no work to do)" >&2
            return 1
            ;;
    esac

    if ! printf '%s\n' $labels | grep -qxF "$expected"; then
        echo "[handler-guard] $kind #$num: trigger label '$expected' no longer present (labels: ${labels:-<none>}) — skipping" >&2
        return 1
    fi

    return 0
}
