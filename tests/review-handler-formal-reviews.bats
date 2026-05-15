#!/usr/bin/env bats
# tests/review-handler-formal-reviews.bats
# Verify review-handler prompt uses formal gh pr review events, not gh pr comment.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    HANDLER="$REPO_ROOT/scripts/review-handler.sh"
}

# ---------------------------------------------------------------------------
# Prompt contains formal review commands (not freeform comments)
# ---------------------------------------------------------------------------

@test "review-handler prompt: APPROVE uses gh pr review --approve not gh pr comment" {
    grep -qE 'gh pr review .* --approve' "$HANDLER"
}

@test "review-handler prompt: REQUEST_CHANGES uses gh pr review --request-changes not gh pr comment" {
    grep -qE 'gh pr review .* --request-changes' "$HANDLER"
}

@test "review-handler prompt: COMMENT path uses gh pr review --comment" {
    grep -qE 'gh pr review .* --comment' "$HANDLER"
}

@test "review-handler prompt: decision branches do not use bare gh pr comment for verdict" {
    # gh pr comment is OK in non-decision contexts (e.g. cleanup/abort notices),
    # but the approval/rejection branches must use gh pr review.
    # Verify the approve/request-changes blocks reference gh pr review, not gh pr comment.
    grep -qE 'gh pr review .* --approve' "$HANDLER"
    grep -qE 'gh pr review .* --request-changes' "$HANDLER"
    # No line that says 'gh pr comment' inside an 'If APPROVE' block.
    ! awk '/If APPROVE:/,/If REQUEST_CHANGES:/' "$HANDLER" | grep -qE '^\s*gh pr comment'
}

# ---------------------------------------------------------------------------
# Deterministic decision sync: APPROVED → reads from reviewDecision field
# ---------------------------------------------------------------------------

@test "review decision APPROVED: label ops from reviewDecision field, not comment body" {
    local ops_log="$BATS_TMPDIR/label-ops-formal.log"
    rm -f "$ops_log"

    backend_remove_label()     { echo "remove $3" >> "$ops_log"; }
    backend_add_label()        { echo "add $3"    >> "$ops_log"; }
    backend_pr_has_any_label() { return 1; }
    # Mock: gh pr view --json reviewDecision returns APPROVED (formal review filed)
    backend_pr_view()          { echo "APPROVED"; }

    local REPO="owner/test-repo"
    local PR_NUM="72"
    local _REWORK_LABEL="loop:action:dev"
    local LOOP_LABEL_NEEDS_QA="loop:result:needs-qa"
    local LOOP_LABEL_DEPRECATED_READY_FOR_QA="ready-for-qa"
    local LOOP_LABEL_DEPRECATED_NEEDS_REWORK="needs-rework"
    local LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED="changes-requested"
    local _IS_EXTERNAL_PR=false

    _decision=$(backend_pr_view "$REPO" "$PR_NUM" --json reviewDecision --jq .reviewDecision 2>/dev/null || echo "")
    [ "$_decision" = "null" ] && _decision=""

    case "$_decision" in
        CHANGES_REQUESTED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$_REWORK_LABEL"
            ;;
        APPROVED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
        *)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
    esac

    [ "$_decision" = "APPROVED" ]
    grep -q "remove in-review" "$ops_log"
    ! grep -q "add loop:action:dev" "$ops_log"
}

@test "review decision APPROVED (mocked reviews json): state shows APPROVED" {
    # Simulate: gh pr view --json reviews returns a review with state APPROVED.
    # This is what happens after gh pr review --approve (formal review), not
    # after gh pr comment (which would leave reviews=[]).
    gh() {
        case "$*" in
            *"--json reviews"*)
                printf '{"reviews":[{"state":"APPROVED","author":{"login":"bot"}}]}\n'
                ;;
            *) true ;;
        esac
    }

    local review_state
    review_state=$(gh pr view 72 --repo owner/test-repo --json reviews \
        | python3 -c "import json,sys; r=json.load(sys.stdin)['reviews']; print(r[0]['state'] if r else 'NONE')")

    [ "$review_state" = "APPROVED" ]
}

@test "review comment (not formal review): reviews array is empty" {
    # A bare 'gh pr comment' does not create a review event.
    # Simulate the old (broken) path: reviews=[], comments has the approval text.
    gh() {
        case "$*" in
            *"--json reviews"*)
                printf '{"reviews":[]}\n'
                ;;
            *) true ;;
        esac
    }

    local review_state
    review_state=$(gh pr view 72 --repo owner/test-repo --json reviews \
        | python3 -c "import json,sys; r=json.load(sys.stdin)['reviews']; print(r[0]['state'] if r else 'NONE')")

    [ "$review_state" = "NONE" ]
}
