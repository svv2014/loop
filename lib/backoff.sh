#!/usr/bin/env bash
# lib/backoff.sh — Exponential backoff for handler retries (#153).
#
# Per-(slug, number, stage) state file in $LOOP_BACKOFF_DIR. Each entry
# stores: failure count, next-eligible epoch, last failure detail.
#
# Usage from a handler:
#   source "$LOOP_ROOT/lib/backoff.sh"
#   if ! loop_backoff_check "$SLUG" "$ISSUE_NUM" dev; then
#       exit 0   # still cooling down; reconciler will retry naturally
#   fi
#   ... do work ...
#   if [ "$exit_code" -ne 0 ]; then
#       loop_backoff_record_failure "$SLUG" "$ISSUE_NUM" dev "agent timeout"
#   else
#       loop_backoff_clear "$SLUG" "$ISSUE_NUM" dev
#   fi
#
# Schedule (configurable via LOOP_BACKOFF_SCHEDULE env, default below):
#   attempt 1: no wait
#   attempt 2: 30s
#   attempt 3: 60s
#   attempt 4: 120s
#   attempt 5+: 300s (cap)
#
# Cap policy: after LOOP_BACKOFF_MAX_AT_CAP retries at the 300s cap (default
# 3), the reconciler should mark the ticket `blocked` for operator review.
# That logic lives in scanner/reconciler.sh::reconcile_backoff_exhausted.

[ -n "${_LOOP_BACKOFF_LOADED:-}" ] && return 0
_LOOP_BACKOFF_LOADED=1

LOOP_BACKOFF_DIR="${LOOP_BACKOFF_DIR:-/tmp/loop-backoff}"
LOOP_BACKOFF_SCHEDULE="${LOOP_BACKOFF_SCHEDULE:-0 30 60 120 300}"
LOOP_BACKOFF_MAX_AT_CAP="${LOOP_BACKOFF_MAX_AT_CAP:-3}"

mkdir -p "$LOOP_BACKOFF_DIR" 2>/dev/null || true

# _loop_backoff_path <slug> <num> <stage>
_loop_backoff_path() {
    local slug="$1" num="$2" stage="$3"
    local key="${slug}-${num}-${stage}"
    # Sanitize for filesystem (slugs can contain dots).
    key="${key//[^A-Za-z0-9_-]/_}"
    printf '%s/%s' "$LOOP_BACKOFF_DIR" "$key"
}

# _loop_backoff_delay_for_attempt <attempt_count>
# Returns the delay in seconds for the Nth retry (1-indexed).
_loop_backoff_delay_for_attempt() {
    local n="$1"
    # shellcheck disable=SC2206
    local schedule=( $LOOP_BACKOFF_SCHEDULE )
    local last_idx=$(( ${#schedule[@]} - 1 ))
    if [ "$n" -le 0 ]; then
        echo 0
    elif [ "$n" -gt "$last_idx" ]; then
        echo "${schedule[$last_idx]}"
    else
        echo "${schedule[$n]}"
    fi
}

# loop_backoff_check <slug> <num> <stage>
# Returns 0 if the handler is eligible to run, 1 if still in backoff.
loop_backoff_check() {
    local path
    path=$(_loop_backoff_path "$1" "$2" "$3")
    [ -f "$path" ] || return 0

    local next_eligible
    next_eligible=$(awk -F: '/^next_eligible:/{print $2}' "$path" 2>/dev/null | tr -d '[:space:]')
    [ -z "$next_eligible" ] && return 0

    local now; now=$(date +%s)
    if [ "$now" -lt "$next_eligible" ]; then
        return 1
    fi
    return 0
}

# loop_backoff_record_failure <slug> <num> <stage> [detail]
# Increment the failure counter and set next-eligible time.
loop_backoff_record_failure() {
    local slug="$1" num="$2" stage="$3" detail="${4:-}"
    local path; path=$(_loop_backoff_path "$slug" "$num" "$stage")

    local count=0
    if [ -f "$path" ]; then
        count=$(awk -F: '/^count:/{print $2}' "$path" 2>/dev/null | tr -d '[:space:]')
        [ -z "$count" ] && count=0
    fi
    count=$((count + 1))

    local delay; delay=$(_loop_backoff_delay_for_attempt "$count")
    local now; now=$(date +%s)
    local next_eligible=$((now + delay))

    cat > "$path" <<EOF
count:$count
last_failure:$now
next_eligible:$next_eligible
delay:$delay
detail:$detail
EOF
    echo "$count"
}

# loop_backoff_clear <slug> <num> <stage>
# Clear the retry state — call on success or after operator intervention.
loop_backoff_clear() {
    local path; path=$(_loop_backoff_path "$1" "$2" "$3")
    rm -f "$path" 2>/dev/null || true
}

# loop_backoff_count <slug> <num> <stage>
# Print the current failure count (0 if no state).
loop_backoff_count() {
    local path; path=$(_loop_backoff_path "$1" "$2" "$3")
    if [ ! -f "$path" ]; then echo 0; return; fi
    local count
    count=$(awk -F: '/^count:/{print $2}' "$path" 2>/dev/null | tr -d '[:space:]')
    echo "${count:-0}"
}

# loop_backoff_at_cap_count <slug> <num> <stage>
# Print how many of the failures landed at the cap delay. Used by
# reconciler to decide when to escalate to `blocked`.
# Schedule has N entries (index 0..N-1); the last entry is the cap.
# Pre-cap attempts: 1..(N-2). Cap reached on attempt (N-1) onward.
# at_cap_count = max(count - (N-2), 0).
loop_backoff_at_cap_count() {
    local count; count=$(loop_backoff_count "$1" "$2" "$3")
    # shellcheck disable=SC2206
    local schedule=( $LOOP_BACKOFF_SCHEDULE )
    local pre_cap_attempts=$(( ${#schedule[@]} - 2 ))
    local at_cap=$((count - pre_cap_attempts))
    if [ "$at_cap" -lt 0 ]; then echo 0; else echo "$at_cap"; fi
}
