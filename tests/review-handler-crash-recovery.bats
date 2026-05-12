#!/usr/bin/env bats
# tests/review-handler-crash-recovery.bats
#
# Simulates a forced agent crash (loop_run_agent exits 137) and asserts that
# the EXIT trap in review-handler.sh strips `in-review` and re-adds
# `needs-review`, leaving the PR in a retryable state.
#
# The handler itself is NOT sourced as a whole script — doing so would trigger
# real gh calls and require a live repo. Instead the trap logic is replicated
# directly here (same pattern used by tests/review.bats).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"

    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: test-proj
    name: Test Project
    repo: owner/test-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    export COMMENT_LOG="$BATS_TMPDIR/comment.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG"
}

teardown() {
    rm -f "$BATS_TMPDIR/fixture.yaml" "$OPS_LOG" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Helper: replicate the _review_handler_cleanup logic so we can unit-test it
# without sourcing the whole handler.
# ---------------------------------------------------------------------------

_run_cleanup() {
    local rc="$1"
    local has_in_review="$2"    # "yes" | "no"
    local has_terminal="$3"     # "yes" | "no"

    local REPO="owner/test-repo"
    local PR_NUM="42"
    local LOOP_LABEL_IN_REVIEW="in-review"
    local LOOP_LABEL_NEEDS_QA="needs-qa"
    local LOOP_LABEL_DEPRECATED_READY_FOR_QA="ready-for-qa"
    local _REWORK_LABEL="needs-rework"
    local LOOP_LABEL_DEPRECATED_NEEDS_REWORK="needs-rework"
    local LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED="changes-requested"
    local _REVIEW_LABEL="needs-review"

    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_add_label()    { echo "add $3"    >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment: $3" >> "$COMMENT_LOG"; }
    loop_notify()          { :; }
    log()                  { :; }

    backend_pr_has_any_label() {
        # $3 is the first label to check against (in-review, or terminal labels)
        shift 2
        for lbl in "$@"; do
            case "$lbl" in
                in-review)  [ "$has_in_review" = "yes" ] && return 0 ;;
                needs-qa|ready-for-qa|needs-rework|changes-requested|blocked|done)
                    [ "$has_terminal" = "yes" ] && return 0 ;;
            esac
        done
        return 1
    }

    # Replicate _review_handler_cleanup
    if backend_pr_has_any_label "$REPO" "$PR_NUM" \
            "$LOOP_LABEL_IN_REVIEW" 2>/dev/null; then
        if ! backend_pr_has_any_label "$REPO" "$PR_NUM" \
                "$LOOP_LABEL_NEEDS_QA" "$LOOP_LABEL_DEPRECATED_READY_FOR_QA" \
                "$_REWORK_LABEL" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" \
                "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" \
                blocked 'done' 2>/dev/null; then
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_IN_REVIEW" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$_REVIEW_LABEL" 2>/dev/null || true
            backend_comment_pr "$REPO" "$PR_NUM" \
                "Automated review aborted (exit=${rc}). Re-queued for review." \
                2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Test 1: agent crash (exit 137) → PR gets needs-review, not left in in-review
# ---------------------------------------------------------------------------

@test "crash recovery: agent exit 137 strips in-review and adds needs-review" {
    _run_cleanup 137 yes no

    grep -q "remove in-review"   "$OPS_LOG"
    grep -q "add needs-review"   "$OPS_LOG"
    ! grep -q "add in-review"    "$OPS_LOG"
    grep -q "Re-queued for review" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Test 2: cleanup is idempotent — if a decision label is already set, do nothing
# ---------------------------------------------------------------------------

@test "crash recovery: idempotent when terminal decision label already present" {
    _run_cleanup 1 yes yes

    # No label mutations should be written
    [ ! -f "$OPS_LOG" ] || ! grep -q "remove\|add" "$OPS_LOG"
    [ ! -f "$COMMENT_LOG" ] || ! grep -q "." "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Test 3: cleanup does nothing when in-review is already absent
# ---------------------------------------------------------------------------

@test "crash recovery: no-op when in-review is not present" {
    _run_cleanup 0 no no

    [ ! -f "$OPS_LOG" ] || ! grep -q "remove\|add" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 4: happy path — agent exits 0 with a decision label → no cleanup action
# ---------------------------------------------------------------------------

@test "crash recovery: happy path with decision label — cleanup is no-op" {
    _run_cleanup 0 no yes

    [ ! -f "$OPS_LOG" ] || ! grep -q "remove\|add" "$OPS_LOG"
}
