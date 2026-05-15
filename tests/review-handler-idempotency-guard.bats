#!/usr/bin/env bats
# tests/review-handler-idempotency-guard.bats
#
# Pre-flight idempotency guard: when the bot already posted a
# CHANGES_REQUESTED or APPROVED review on the PR's current head SHA,
# review-handler must skip — clear loop:action:review and exit 0 — rather
# than invoke the reviewer agent again.
#
# Companion to LOOP-418's crash-recovery fix. LOOP-418 stopped the trap
# from re-queueing; this guard prevents *any* re-entry path (manual
# relabel, scanner race, operator action) from triggering a re-review on
# unchanged code. Together they make the pipeline consistent even when
# the reviewer agent's verdict is non-deterministic.

setup() {
    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"
    export REPO="owner/test-repo"
    export PR_NUM="42"
    export BACKEND="github"
    export LOOP_LABEL_NEEDS_REVIEW="loop:action:review"
    export LOOP_LABEL_DEPRECATED_REVIEW_PENDING="review-pending"
}

teardown() {
    rm -f "$OPS_LOG"
}

# Replicates the guard block from scripts/review-handler.sh (the inserted
# block between loop_handler_guard and in-review labeling). Inputs are
# injected via the stubs below.
_run_guard() {
    local head_sha="$1"          # value backend_pr_view returns for --json headRefOid
    local bot_login="$2"         # value `gh api user` returns
    local prior_verdict="$3"     # "" | "CHANGES_REQUESTED" | "APPROVED" (what the jq filter returns)

    backend_pr_view() {
        # First arg pattern: <repo> <number> --json <field> --jq <expr> ...
        # We dispatch on the --json field name.
        local args=("$@")
        local i
        for ((i=0; i<${#args[@]}; i++)); do
            if [ "${args[i]}" = "--json" ]; then
                case "${args[i+1]}" in
                    headRefOid) echo "$head_sha"; return 0 ;;
                    reviews)    echo "$prior_verdict"; return 0 ;;
                esac
            fi
        done
        return 0
    }
    gh() {
        if [ "$1" = "api" ] && [ "$2" = "user" ]; then
            echo "$bot_login"; return 0
        fi
        return 0
    }
    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    log() { :; }

    # Block under test — kept in sync with scripts/review-handler.sh
    if [ "${BACKEND:-github}" = "github" ]; then
        _HEAD_SHA=$(backend_pr_view "$REPO" "$PR_NUM" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
        _BOT_LOGIN=$(gh api user --jq '.login' 2>/dev/null || echo "")
        if [ -n "$_HEAD_SHA" ] && [ -n "$_BOT_LOGIN" ]; then
            _PRIOR_VERDICT=$(backend_pr_view "$REPO" "$PR_NUM" --json reviews \
                --jq --arg sha "$_HEAD_SHA" --arg login "$_BOT_LOGIN" \
                '...' \
                2>/dev/null || echo "")
            if [ -n "$_PRIOR_VERDICT" ]; then
                log "idempotency: skip"
                backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_NEEDS_REVIEW" 2>/dev/null || true
                backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING" 2>/dev/null || true
                return 0   # in real script this is `exit 0`
            fi
        fi
    fi
    return 1   # fell through — handler would continue to the reviewer agent
}

@test "guard: skips and clears needs-review when prior CHANGES_REQUESTED exists on head SHA" {
    run _run_guard "deadbeefdeadbeef" "review-bot" "CHANGES_REQUESTED"
    [ "$status" -eq 0 ]
    grep -q "remove loop:action:review" "$OPS_LOG"
}

@test "guard: skips and clears needs-review when prior APPROVED exists on head SHA" {
    run _run_guard "deadbeefdeadbeef" "review-bot" "APPROVED"
    [ "$status" -eq 0 ]
    grep -q "remove loop:action:review" "$OPS_LOG"
}

@test "guard: falls through (no skip) when no prior verdict on this head SHA" {
    run _run_guard "deadbeefdeadbeef" "review-bot" ""
    [ "$status" -eq 1 ]
    [ ! -f "$OPS_LOG" ] || ! grep -q "remove" "$OPS_LOG"
}

@test "guard: falls through when head SHA cannot be resolved" {
    run _run_guard "" "review-bot" "CHANGES_REQUESTED"
    [ "$status" -eq 1 ]
}

@test "guard: falls through when bot login cannot be resolved" {
    run _run_guard "deadbeefdeadbeef" "" "CHANGES_REQUESTED"
    [ "$status" -eq 1 ]
}

@test "guard: no-ops on non-github backend" {
    BACKEND="gitlab" run _run_guard "deadbeefdeadbeef" "review-bot" "CHANGES_REQUESTED"
    [ "$status" -eq 1 ]
}
