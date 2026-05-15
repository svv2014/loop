#!/usr/bin/env bats
# tests/review-handler-blocked-cleanup.bats
#
# QA-driven tests for the PR #419 cleanup-trap change:
# when review-handler exits without a verdict, cleanup must apply
# loop:result:blocked (not re-add loop:action:review).
#
# Also verifies that external-review-fail / external-review-pass and the
# canonical loop:result:blocked / loop:result:done labels are treated as
# terminal (no cleanup fires when they are present).

setup() {
    export OPS_LOG="$BATS_TMPDIR/ops.log"
    export COMMENT_LOG="$BATS_TMPDIR/comment.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG"

    export REPO="owner/test-repo"
    export PR_NUM="42"
    export SLUG="test-proj"
}

teardown() {
    rm -f "$OPS_LOG" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Helper: replicate _review_handler_cleanup (new behavior from PR #419).
# Mirrors scripts/review-handler.sh lines 105-128 after the PR change.
# ---------------------------------------------------------------------------
_run_cleanup() {
    local rc="$1"
    local has_in_review="$2"     # "yes" | "no"
    local terminal_label="$3"    # "" | label name that is present on the PR

    local LOOP_LABEL_IN_REVIEW="in-review"
    local LOOP_LABEL_NEEDS_QA="needs-qa"
    local LOOP_LABEL_DEPRECATED_READY_FOR_QA="ready-for-qa"
    local _REWORK_LABEL="loop:action:rework"
    local LOOP_LABEL_DEPRECATED_NEEDS_REWORK="needs-rework"
    local LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED="changes-requested"
    local _REVIEW_LABEL="loop:action:review"
    local LOOP_LABEL_BLOCKED="loop:result:blocked"
    local LOOP_LABEL_DONE="loop:result:done"
    local LOOP_LABEL_EXTERNAL_REVIEW_FAIL="external-review-fail"
    local LOOP_LABEL_EXTERNAL_REVIEW_PASS="external-review-pass"

    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_add_label()    { echo "add $3"    >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment: $4" >> "$COMMENT_LOG"; }
    loop_notify()          { :; }
    log()                  { :; }

    backend_pr_has_any_label() {
        shift 2
        for lbl in "$@"; do
            [ "$lbl" = "in-review" ] && [ "$has_in_review" = "yes" ] && return 0
            [ -n "$terminal_label" ] && [ "$lbl" = "$terminal_label" ] && return 0
        done
        return 1
    }

    # Replicate the updated _review_handler_cleanup body
    if backend_pr_has_any_label "$REPO" "$PR_NUM" "$LOOP_LABEL_IN_REVIEW" 2>/dev/null; then
        if ! backend_pr_has_any_label "$REPO" "$PR_NUM" \
                "$LOOP_LABEL_NEEDS_QA" "$LOOP_LABEL_DEPRECATED_READY_FOR_QA" \
                "$_REWORK_LABEL" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" \
                "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" \
                "$LOOP_LABEL_EXTERNAL_REVIEW_FAIL" "$LOOP_LABEL_EXTERNAL_REVIEW_PASS" \
                "$LOOP_LABEL_BLOCKED" blocked "$LOOP_LABEL_DONE" 'done' 2>/dev/null; then
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_IN_REVIEW" 2>/dev/null || true
            backend_remove_label "$REPO" "$PR_NUM" "$_REVIEW_LABEL" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$LOOP_LABEL_BLOCKED" 2>/dev/null || true
            backend_comment_pr "$REPO" "$PR_NUM" "" \
                "Automated review aborted without a verdict (exit=${rc}). Marked as blocked — operator action needed." \
                2>/dev/null || true
        fi
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# AC2 — no-verdict exit applies loop:result:blocked, NOT loop:action:review
# ---------------------------------------------------------------------------

@test "cleanup: no-verdict exit applies loop:result:blocked" {
    _run_cleanup 0 yes ""
    grep -q "add loop:result:blocked" "$OPS_LOG"
}

@test "cleanup: no-verdict exit removes loop:action:review" {
    _run_cleanup 0 yes ""
    grep -q "remove loop:action:review" "$OPS_LOG"
}

@test "cleanup: no-verdict exit does NOT re-add loop:action:review" {
    _run_cleanup 0 yes ""
    ! grep -q "add loop:action:review" "$OPS_LOG"
}

@test "cleanup: no-verdict exit posts operator comment" {
    _run_cleanup 0 yes ""
    grep -q "blocked — operator action needed" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Terminal labels that must suppress cleanup (extended list from PR #419)
# ---------------------------------------------------------------------------

@test "cleanup: external-review-fail is terminal — no cleanup action" {
    _run_cleanup 0 yes "external-review-fail"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add\|remove" "$OPS_LOG"
}

@test "cleanup: external-review-pass is terminal — no cleanup action" {
    _run_cleanup 0 yes "external-review-pass"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add\|remove" "$OPS_LOG"
}

@test "cleanup: loop:result:blocked already present — no cleanup action" {
    _run_cleanup 0 yes "loop:result:blocked"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add\|remove" "$OPS_LOG"
}

@test "cleanup: loop:result:done already present — no cleanup action" {
    _run_cleanup 0 yes "loop:result:done"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add\|remove" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Unchanged guard conditions
# ---------------------------------------------------------------------------

@test "cleanup: no-op when in-review is absent" {
    _run_cleanup 0 no ""
    [ ! -f "$OPS_LOG" ] || ! grep -q "add\|remove" "$OPS_LOG"
}

@test "cleanup: needs-qa present — no cleanup action" {
    _run_cleanup 0 yes "needs-qa"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add\|remove" "$OPS_LOG"
}
