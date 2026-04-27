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
# asdlc_issue_has_any_label
# ---------------------------------------------------------------------------

@test "asdlc_issue_has_any_label: returns 0 when label is present" {
    export GH_MOCK_OUTPUT="dev
enhancement"
    run asdlc_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 0 ]
}

@test "asdlc_issue_has_any_label: returns 0 when one of several wanted labels matches" {
    export GH_MOCK_OUTPUT="review-pending"
    run asdlc_issue_has_any_label "owner/repo" 1 "dev" "review-pending"
    [ "$status" -eq 0 ]
}

@test "asdlc_issue_has_any_label: returns 1 when label is absent" {
    export GH_MOCK_OUTPUT="enhancement"
    run asdlc_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 1 ]
}

@test "asdlc_issue_has_any_label: returns 1 when gh fails" {
    export GH_MOCK_EXIT=1
    run asdlc_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 1 ]
}

@test "asdlc_issue_has_any_label: returns 1 when output is empty" {
    export GH_MOCK_OUTPUT=""
    run asdlc_issue_has_any_label "owner/repo" 1 "dev"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# asdlc_pr_has_any_label
# ---------------------------------------------------------------------------

@test "asdlc_pr_has_any_label: returns 0 when label is present" {
    export GH_MOCK_OUTPUT="review-pending"
    run asdlc_pr_has_any_label "owner/repo" 5 "review-pending"
    [ "$status" -eq 0 ]
}

@test "asdlc_pr_has_any_label: returns 0 when one of several wanted labels matches" {
    export GH_MOCK_OUTPUT="qa-pass"
    run asdlc_pr_has_any_label "owner/repo" 5 "in-review" "qa-pass"
    [ "$status" -eq 0 ]
}

@test "asdlc_pr_has_any_label: returns 1 when label is absent" {
    export GH_MOCK_OUTPUT="dev"
    run asdlc_pr_has_any_label "owner/repo" 5 "review-pending"
    [ "$status" -eq 1 ]
}

@test "asdlc_pr_has_any_label: returns 1 when gh fails" {
    export GH_MOCK_EXIT=1
    run asdlc_pr_has_any_label "owner/repo" 5 "review-pending"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# asdlc_add_label
# ---------------------------------------------------------------------------

@test "asdlc_add_label: succeeds with mocked gh" {
    export GH_MOCK_EXIT=0
    run asdlc_add_label "owner/repo" 1 "in-progress"
    [ "$status" -eq 0 ]
}

@test "asdlc_add_label: succeeds even when gh returns non-zero (or true)" {
    export GH_MOCK_EXIT=1
    run asdlc_add_label "owner/repo" 1 "in-progress"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# asdlc_remove_label
# ---------------------------------------------------------------------------

@test "asdlc_remove_label: succeeds with mocked gh" {
    export GH_MOCK_EXIT=0
    run asdlc_remove_label "owner/repo" 1 "dev"
    [ "$status" -eq 0 ]
}

@test "asdlc_remove_label: succeeds even when gh returns non-zero (or true)" {
    export GH_MOCK_EXIT=1
    run asdlc_remove_label "owner/repo" 1 "dev"
    [ "$status" -eq 0 ]
}
