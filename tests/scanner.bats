#!/usr/bin/env bats
# tests/scanner.bats — unit tests for stateless logic in scanner/scanner.sh.
# All gh calls are intercepted by the mock binary in test_helper/.
#
# Sourcing strategy: awk extracts all function/variable definitions from
# scanner.sh and stops before the bare "acquire_lock" call that would start
# the daemon loop. SCRIPT_DIR/ASDLC_ROOT lines are skipped; ASDLC_ROOT is
# injected first so the lib/ source statements resolve correctly.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Pre-set log dir so env.sh does not create ~/.asdlc/logs during tests.
    export ASDLC_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$ASDLC_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh function definitions only.
    # - Inject ASDLC_ROOT before awk output so lib/ sources resolve.
    # - Strip the SCRIPT_DIR= and ASDLC_ROOT= re-assignments from scanner.sh
    #   (env.sh uses BASH_SOURCE[0] and will set ASDLC_ROOT correctly anyway).
    # - Stop awk at the bare "acquire_lock" call to avoid the daemon loop.
    # shellcheck disable=SC1090
    source <(
        printf "ASDLC_ROOT='%s'\n" "$REPO_ROOT"
        awk '
            /^SCRIPT_DIR=/  { next }
            /^ASDLC_ROOT=/  { next }
            /^acquire_lock$/ { exit }
            { print }
        ' "$REPO_ROOT/scanner/scanner.sh"
    )

    # Override paths that scanner.sh hard-codes after sourcing.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    # Ensure emit uses direct mode with no event-queue client.
    DRY_RUN=false
    ASDLC_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() output; no-op dispatch_direct to avoid launching handlers.
    log() { :; }
    dispatch_direct() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _dedup_key
# ---------------------------------------------------------------------------

@test "_dedup_key: produces non-empty output" {
    run _dedup_key "asdlc.dev_issue:owner/repo:42"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "_dedup_key: same input yields same hash" {
    local a b
    a=$(_dedup_key "asdlc.dev_issue:test-org/test-repo:7")
    b=$(_dedup_key "asdlc.dev_issue:test-org/test-repo:7")
    [ "$a" = "$b" ]
}

@test "_dedup_key: different inputs yield different hashes" {
    local a b
    a=$(_dedup_key "asdlc.dev_issue:test-org/test-repo:1")
    b=$(_dedup_key "asdlc.dev_issue:test-org/test-repo:2")
    [ "$a" != "$b" ]
}

# ---------------------------------------------------------------------------
# issue_is_claimed
# ---------------------------------------------------------------------------

@test "issue_is_claimed: returns 0 when issue has in-progress label" {
    export GH_MOCK_OUTPUT="in-progress"
    run issue_is_claimed "owner/repo" 1
    [ "$status" -eq 0 ]
}

@test "issue_is_claimed: returns 0 when issue has review-pending label" {
    export GH_MOCK_OUTPUT="review-pending"
    run issue_is_claimed "owner/repo" 1
    [ "$status" -eq 0 ]
}

@test "issue_is_claimed: returns 0 when issue has qa-pass label" {
    export GH_MOCK_OUTPUT="qa-pass"
    run issue_is_claimed "owner/repo" 1
    [ "$status" -eq 0 ]
}

@test "issue_is_claimed: returns 1 when issue has only dev label" {
    export GH_MOCK_OUTPUT="dev"
    run issue_is_claimed "owner/repo" 1
    [ "$status" -eq 1 ]
}

@test "issue_is_claimed: returns 1 when issue has no labels" {
    export GH_MOCK_OUTPUT=""
    run issue_is_claimed "owner/repo" 1
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pr_is_claimed_for_review
# ---------------------------------------------------------------------------

@test "pr_is_claimed_for_review: returns 0 when PR has in-review label" {
    export GH_MOCK_OUTPUT="in-review"
    run pr_is_claimed_for_review "owner/repo" 5
    [ "$status" -eq 0 ]
}

@test "pr_is_claimed_for_review: returns 0 when PR has qa-pass label" {
    export GH_MOCK_OUTPUT="qa-pass"
    run pr_is_claimed_for_review "owner/repo" 5
    [ "$status" -eq 0 ]
}

@test "pr_is_claimed_for_review: returns 1 when PR has only review-pending" {
    export GH_MOCK_OUTPUT="review-pending"
    run pr_is_claimed_for_review "owner/repo" 5
    [ "$status" -eq 1 ]
}

@test "pr_is_claimed_for_review: returns 1 when PR has no relevant labels" {
    export GH_MOCK_OUTPUT="dev"
    run pr_is_claimed_for_review "owner/repo" 5
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pr_is_claimed_for_qa
# ---------------------------------------------------------------------------

@test "pr_is_claimed_for_qa: returns 0 when PR has qa-pass label" {
    export GH_MOCK_OUTPUT="qa-pass"
    run pr_is_claimed_for_qa "owner/repo" 5
    [ "$status" -eq 0 ]
}

@test "pr_is_claimed_for_qa: returns 0 when PR has done label" {
    export GH_MOCK_OUTPUT="done"
    run pr_is_claimed_for_qa "owner/repo" 5
    [ "$status" -eq 0 ]
}

@test "pr_is_claimed_for_qa: returns 1 when PR has only ready-for-qa" {
    export GH_MOCK_OUTPUT="ready-for-qa"
    run pr_is_claimed_for_qa "owner/repo" 5
    [ "$status" -eq 1 ]
}

@test "pr_is_claimed_for_qa: returns 1 when PR has only review-pending" {
    export GH_MOCK_OUTPUT="review-pending"
    run pr_is_claimed_for_qa "owner/repo" 5
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pr_is_claimed_for_rework
# ---------------------------------------------------------------------------

@test "pr_is_claimed_for_rework: returns 0 when PR has in-rework label" {
    export GH_MOCK_OUTPUT="in-rework"
    run pr_is_claimed_for_rework "owner/repo" 5
    [ "$status" -eq 0 ]
}

@test "pr_is_claimed_for_rework: returns 0 when PR has blocked label" {
    export GH_MOCK_OUTPUT="blocked"
    run pr_is_claimed_for_rework "owner/repo" 5
    [ "$status" -eq 0 ]
}

@test "pr_is_claimed_for_rework: returns 1 when PR has only changes-requested" {
    export GH_MOCK_OUTPUT="changes-requested"
    run pr_is_claimed_for_rework "owner/repo" 5
    [ "$status" -eq 1 ]
}

@test "pr_is_claimed_for_rework: returns 1 when PR has no relevant labels" {
    export GH_MOCK_OUTPUT="review-pending"
    run pr_is_claimed_for_rework "owner/repo" 5
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# emit (dedup behavior)
# Calls are made without `run` so function definitions in this scope apply.
# ---------------------------------------------------------------------------

@test "emit: creates dedup key file after dispatch" {
    dispatch_direct() { return 0; }
    export GH_MOCK_OUTPUT=""

    local json='{"type":"asdlc.dev_issue","payload":{"slug":"test","repo":"owner/repo"}}'
    emit "$json" "dev_issue:owner/repo:10"

    local key
    key=$(_dedup_key "dev_issue:owner/repo:10")
    [ -f "$DEDUP_DIR/$key" ]
}

@test "emit: calls dispatch_direct when no dedup key exists" {
    local dispatch_log="$BATS_TMPDIR/dispatch.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local json='{"type":"asdlc.dev_issue","payload":{"slug":"test","repo":"owner/repo"}}'
    emit "$json" "dev_issue:owner/repo:11"

    [ -f "$dispatch_log" ]
}

@test "emit: skips dispatch when key file is recent" {
    # stat -f%m is macOS-specific; skip on platforms where it is unavailable.
    local key
    key=$(_dedup_key "dev_issue:owner/repo:12")
    touch "$DEDUP_DIR/$key"
    if ! stat -f%m "$DEDUP_DIR/$key" 2>/dev/null; then
        skip "stat -f%m not available on this platform"
    fi

    local dispatch_log="$BATS_TMPDIR/dispatch2.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local json='{"type":"asdlc.dev_issue","payload":{}}'
    emit "$json" "dev_issue:owner/repo:12"

    [ ! -f "$dispatch_log" ]
}

@test "emit: no dedup key file created when dedup_id is empty" {
    local dispatch_log="$BATS_TMPDIR/dispatch3.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local before_count
    before_count=$(find "$DEDUP_DIR" -type f | wc -l)

    local json='{"type":"asdlc.dev_issue","payload":{}}'
    emit "$json" ""

    local after_count
    after_count=$(find "$DEDUP_DIR" -type f | wc -l)
    [ "$before_count" -eq "$after_count" ]
}
