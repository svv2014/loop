#!/usr/bin/env bats
# tests/merge-handler-fork-gate.bats
# Regression tests for the fork-origin gate in merge-handler.sh.
#
# Covers: (a) fork PR → needs-human-merge label added, no merge attempted,
# exit 0; (b) same-owner PR → merge path invoked normally.

setup() {
    OPS_LOG="$BATS_TMPDIR/label-ops.log"
    COMMENT_LOG="$BATS_TMPDIR/comment.log"
    MERGE_LOG="$BATS_TMPDIR/merge.log"
    BOUNTY_LOG="$BATS_TMPDIR/bounty.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$MERGE_LOG" "$BOUNTY_LOG"

    export REPO="owner/test-repo"
    export PR_NUM="10"
    export BASE_OWNER="owner"
    export LOG_FILE="$BATS_TMPDIR/handler.log"
    export LOOP_AGENT_MODEL="sonnet"
}

teardown() {
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$MERGE_LOG" "$BOUNTY_LOG" \
          "$BATS_TMPDIR/handler.log"
}

# ---------------------------------------------------------------------------
# Helper: inline the fork-origin gate block from merge-handler.sh so we can
# unit-test it without sourcing the full handler (which requires loop_env etc.)
# ---------------------------------------------------------------------------
_run_fork_gate() {
    local head_owner="$1"

    backend_add_label()    { echo "add $3"    >> "$OPS_LOG"; }
    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment: $4" >> "$COMMENT_LOG"; }
    backend_merge_pr()     { echo "merged" >> "$MERGE_LOG"; }
    backend_pr_view() {
        # Return JSON with the head owner we were given
        printf '{"headRepositoryOwner":{"login":"%s"}}' "$head_owner"
    }
    log() { true; }

    # Replicate the fork-origin gate block exactly as written in the handler.
    local BASE_OWNER_LOCAL="${REPO%%/*}"
    local HEAD_OWNER
    HEAD_OWNER=$(backend_pr_view "$REPO" "$PR_NUM" --json headRepositoryOwner 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('headRepositoryOwner',{}).get('login',''))" 2>/dev/null || echo "")

    if [ -z "$HEAD_OWNER" ] || [ "$HEAD_OWNER" != "$BASE_OWNER_LOCAL" ]; then
        log "PR #${PR_NUM} is from a fork (head owner='${HEAD_OWNER}', base owner='${BASE_OWNER_LOCAL}') — skipping auto-merge"
        backend_add_label "$REPO" "$PR_NUM" needs-human-merge
        backend_remove_label "$REPO" "$PR_NUM" qa-pass
        backend_comment_pr "$REPO" "$PR_NUM" "" \
            "Loop does not auto-merge PRs from forks for security reasons (fork tests + post-merge hooks can execute untrusted code). Labelled \`needs-human-merge\` — an operator must review and merge manually."
        return 0
    fi

    # Same-owner: invoke the merge path
    backend_merge_pr "$REPO" "$PR_NUM" "--squash"
}

# ---------------------------------------------------------------------------
# Test (a): fork PR → labelled needs-human-merge, no merge attempted, exit 0
# ---------------------------------------------------------------------------

@test "fork PR: needs-human-merge label added" {
    _run_fork_gate "other-org"
    grep -q "add needs-human-merge" "$OPS_LOG"
}

@test "fork PR: qa-pass trigger label removed" {
    _run_fork_gate "other-org"
    grep -q "remove qa-pass" "$OPS_LOG"
}

@test "fork PR: explanatory comment posted" {
    _run_fork_gate "other-org"
    grep -qi "fork" "$COMMENT_LOG"
    grep -qi "needs-human-merge" "$COMMENT_LOG"
}

@test "fork PR: backend_merge_pr NOT called" {
    _run_fork_gate "other-org"
    [ ! -f "$MERGE_LOG" ] || ! grep -q "merged" "$MERGE_LOG"
}

@test "fork PR: gate exits 0 (clean exit)" {
    run _run_fork_gate "other-org"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test: empty/missing headRepositoryOwner → treated as fork (safe default)
# ---------------------------------------------------------------------------

@test "missing head owner: treated as fork, needs-human-merge added" {
    # Override backend_pr_view to return empty object
    backend_pr_view() { echo '{}'; }

    backend_add_label()    { echo "add $3"    >> "$OPS_LOG"; }
    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment: $4" >> "$COMMENT_LOG"; }
    backend_merge_pr()     { echo "merged" >> "$MERGE_LOG"; }
    log() { true; }

    local BASE_OWNER_LOCAL="${REPO%%/*}"
    local HEAD_OWNER
    HEAD_OWNER=$(backend_pr_view "$REPO" "$PR_NUM" --json headRepositoryOwner 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('headRepositoryOwner',{}).get('login',''))" 2>/dev/null || echo "")

    if [ -z "$HEAD_OWNER" ] || [ "$HEAD_OWNER" != "$BASE_OWNER_LOCAL" ]; then
        backend_add_label "$REPO" "$PR_NUM" needs-human-merge
        backend_remove_label "$REPO" "$PR_NUM" qa-pass
    else
        backend_merge_pr "$REPO" "$PR_NUM" "--squash"
    fi

    grep -q "add needs-human-merge" "$OPS_LOG"
    [ ! -f "$MERGE_LOG" ] || ! grep -q "merged" "$MERGE_LOG"
}

# ---------------------------------------------------------------------------
# Test (b): same-owner PR → merge path invoked, no needs-human-merge label
# ---------------------------------------------------------------------------

@test "same-owner PR: merge path invoked" {
    _run_fork_gate "owner"
    grep -q "merged" "$MERGE_LOG"
}

@test "same-owner PR: needs-human-merge label NOT added" {
    _run_fork_gate "owner"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add needs-human-merge" "$OPS_LOG"
}

@test "same-owner PR: no comment posted" {
    _run_fork_gate "owner"
    [ ! -f "$COMMENT_LOG" ] || [ ! -s "$COMMENT_LOG" ]
}
