#!/usr/bin/env bats
# tests/github.bats — unit tests for lib/github.sh helper functions.
# All gh calls are intercepted by the mock binary in test_helper/.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # shellcheck source=../lib/github.sh
    source "$REPO_ROOT/lib/github.sh"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# loop_issue_has_any_label
# ---------------------------------------------------------------------------

@test "loop_issue_has_any_label: returns 0 when label is present" {
    export GH_MOCK_OUTPUT="dev
enhancement"
    run loop_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 0 ]
}

@test "loop_issue_has_any_label: returns 0 when one of several wanted labels matches" {
    export GH_MOCK_OUTPUT="review-pending"
    run loop_issue_has_any_label "owner/repo" 1 "dev" "review-pending"
    [ "$status" -eq 0 ]
}

@test "loop_issue_has_any_label: returns 1 when label is absent" {
    export GH_MOCK_OUTPUT="enhancement"
    run loop_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 1 ]
}

@test "loop_issue_has_any_label: returns 1 when gh fails" {
    export GH_MOCK_EXIT=1
    run loop_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 1 ]
}

@test "loop_issue_has_any_label: returns 1 when output is empty" {
    export GH_MOCK_OUTPUT=""
    run loop_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# loop_pr_has_any_label
# ---------------------------------------------------------------------------

@test "loop_pr_has_any_label: returns 0 when label is present" {
    export GH_MOCK_OUTPUT="review-pending"
    run loop_pr_has_any_label "owner/repo" 5 "review-pending"
    [ "$status" -eq 0 ]
}

@test "loop_pr_has_any_label: returns 0 when one of several wanted labels matches" {
    export GH_MOCK_OUTPUT="qa-pass"
    run loop_pr_has_any_label "owner/repo" 5 "in-review" "qa-pass"
    [ "$status" -eq 0 ]
}

@test "loop_pr_has_any_label: returns 1 when label is absent" {
    export GH_MOCK_OUTPUT="dev"
    run loop_pr_has_any_label "owner/repo" 5 "review-pending"
    [ "$status" -eq 1 ]
}

@test "loop_pr_has_any_label: returns 1 when gh fails" {
    export GH_MOCK_EXIT=1
    run loop_pr_has_any_label "owner/repo" 5 "review-pending"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# loop_add_label
# ---------------------------------------------------------------------------

@test "loop_add_label: succeeds with mocked gh" {
    export GH_MOCK_EXIT=0
    run loop_add_label "owner/repo" 1 "in-progress"
    [ "$status" -eq 0 ]
}

@test "loop_add_label: succeeds even when gh returns non-zero (or true)" {
    export GH_MOCK_EXIT=1
    run loop_add_label "owner/repo" 1 "in-progress"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# loop_remove_label
# ---------------------------------------------------------------------------

@test "loop_remove_label: succeeds with mocked gh" {
    export GH_MOCK_EXIT=0
    run loop_remove_label "owner/repo" 1 "dev"
    [ "$status" -eq 0 ]
}

@test "loop_remove_label: succeeds even when gh returns non-zero (or true)" {
    export GH_MOCK_EXIT=1
    run loop_remove_label "owner/repo" 1 "dev"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# loop_gh_comment
# ---------------------------------------------------------------------------

@test "loop_gh_comment: body is prefixed with [loop:<handler_id>]" {
    export GH_MOCK_LOG="$BATS_TMPDIR/gh.log"
    run loop_gh_comment "owner/repo" 42 "judge" "Great work"
    [ "$status" -eq 0 ]
    grep -q '\[loop:judge\]' "$GH_MOCK_LOG"
}

@test "loop_gh_comment: review stage tag" {
    export GH_MOCK_LOG="$BATS_TMPDIR/gh.log"
    run loop_gh_comment "owner/repo" 7 "review" "LGTM"
    [ "$status" -eq 0 ]
    grep -q '\[loop:review\]' "$GH_MOCK_LOG"
}

@test "loop_gh_comment: succeeds even when gh returns non-zero" {
    export GH_MOCK_EXIT=1
    run loop_gh_comment "owner/repo" 1 "qa" "all good"
    [ "$status" -eq 0 ]
}

@test "no direct gh pr comment/review calls at line start in scripts/" {
    run grep -rE '^gh pr (comment|review)' "$REPO_ROOT/scripts/"
    [ "$status" -eq 1 ]
}
