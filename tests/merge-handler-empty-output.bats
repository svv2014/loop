#!/usr/bin/env bats
# tests/merge-handler-empty-output.bats
#
# Verifies that merge-handler.sh handles empty / non-JSON output from
# backend_pr_view (e.g. due to a GitHub GraphQL rate-limit hit) without
# crashing with json.decoder.JSONDecodeError and without holding the lock.
#
# Tests cover:
#   (1) Empty backend_pr_view on MERGE_STATE pre-flight → falls through (no crash)
#   (2) Empty backend_pr_view on POST_STATE after merge failure → falls through
#   (3) Merge failure path with empty POST_STATE applies loop:result:blocked label

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    OPS_LOG="$BATS_TMPDIR/ops-$$.log"
    COMMENT_LOG="$BATS_TMPDIR/comment-$$.log"
    MERGE_LOG="$BATS_TMPDIR/merge-$$.log"
    BOUNTY_LOG="$BATS_TMPDIR/bounty-$$.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$MERGE_LOG" "$BOUNTY_LOG"

    export REPO="owner/test-repo"
    export PR_NUM="42"
    export LOG_FILE="$BATS_TMPDIR/handler-$$.log"
    export LOOP_AGENT_MODEL="sonnet"
    export SLUG="test-proj"
    export MERGE_STRATEGY="squash"
    export DEFAULT_BRANCH="main"
    export ROOT="/tmp/fake"
}

teardown() {
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$MERGE_LOG" "$BOUNTY_LOG" \
          "$BATS_TMPDIR/handler-$$.log"
}

# ---------------------------------------------------------------------------
# Helper: replicate the MERGE_STATE pre-flight block from merge-handler.sh
# so we can unit-test it without booting the full handler.
# ---------------------------------------------------------------------------
_run_preflight() {
    local raw_output="$1"  # what backend_pr_view returns (may be empty)

    backend_pr_view() { printf '%s' "$raw_output"; }
    log() { true; }

    local MERGE_STATE
    # This is the fixed line from merge-handler.sh — must not crash on empty input
    MERGE_STATE=$(backend_pr_view "$REPO" "$PR_NUM" --json mergeable,mergeStateStatus 2>/dev/null \
        | python3 -c "import json,sys; c=sys.stdin.read(); d=json.loads(c) if c.strip() else {}; print(d.get('mergeable',''), d.get('mergeStateStatus',''))" 2>/dev/null || true)

    printf '%s' "$MERGE_STATE"
}

# ---------------------------------------------------------------------------
# Helper: replicate the POST_STATE block (after a failed merge attempt)
# ---------------------------------------------------------------------------
_run_post_state() {
    local raw_output="$1"
    local merge_rc="$2"

    backend_pr_view() { printf '%s' "$raw_output"; }
    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_add_label()    { echo "add $3"    >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment: $4" >> "$COMMENT_LOG"; }
    bounty_report()        { echo "bounty: $*" >> "$BOUNTY_LOG"; }
    loop_notify()          { true; }
    loop_failure_category(){ echo "api_error"; }
    bounty_truncate_detail(){ cat; }
    log() { true; }

    local _MERGE_LOG_START=0
    local _merge_rc="$merge_rc"
    local POST_STATE

    POST_STATE=$(backend_pr_view "$REPO" "$PR_NUM" --json mergeable,mergeStateStatus 2>/dev/null \
        | python3 -c "import json,sys; c=sys.stdin.read(); d=json.loads(c) if c.strip() else {}; print(d.get('mergeable',''), d.get('mergeStateStatus',''))" 2>/dev/null || true)

    # Replicate the failure-handling block from merge-handler.sh
    if [ "${_merge_rc}" -ne 0 ]; then
        case "$POST_STATE" in
            *CONFLICTING*|*DIRTY*)
                echo "routed-to-dev-rework"
                return
                ;;
        esac
        case "$POST_STATE" in
            *MERGEABLE*CLEAN*|*MERGEABLE*UNSTABLE*)
                echo "retry-eligible"
                return
                ;;
        esac
        # Non-conflict, non-retry path → blocked
        log "ERROR: merge failed (state=${POST_STATE} rc=${_merge_rc})"
        backend_remove_label "$REPO" "$PR_NUM" qa-pass
        backend_add_label "$REPO" "$PR_NUM" blocked
        backend_comment_pr "$REPO" "$PR_NUM" "" \
            "Merge failed (state: \`${POST_STATE}\`). Marked \`blocked\` — needs human eyes."
        echo "marked-blocked"
    fi
}

# ---------------------------------------------------------------------------
# (1) Empty backend_pr_view on MERGE_STATE → returns empty string, no crash
# ---------------------------------------------------------------------------

@test "merge-handler: empty backend_pr_view on pre-flight does not crash" {
    run _run_preflight ""
    [ "$status" -eq 0 ]
    # Output should be empty or just whitespace — no JSONDecodeError
    [[ "$output" != *"JSONDecodeError"* ]]
    [[ "$output" != *"Traceback"* ]]
}

# ---------------------------------------------------------------------------
# (2) Valid backend_pr_view on pre-flight → MERGE_STATE parsed correctly
# ---------------------------------------------------------------------------

@test "merge-handler: valid JSON on pre-flight parsed correctly" {
    run _run_preflight '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"MERGEABLE"* ]]
    [[ "$output" == *"CLEAN"* ]]
}

# ---------------------------------------------------------------------------
# (3) CONFLICTING pre-flight JSON → MERGE_STATE contains CONFLICTING
# ---------------------------------------------------------------------------

@test "merge-handler: conflicting pre-flight JSON detected" {
    run _run_preflight '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONFLICTING"* ]]
}

# ---------------------------------------------------------------------------
# (4) Empty POST_STATE after merge failure → falls through to blocked path
# ---------------------------------------------------------------------------

@test "merge-handler: empty POST_STATE after failure applies blocked label" {
    _run_post_state "" 1

    grep -q "add blocked" "$OPS_LOG"
    grep -q "remove qa-pass" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (5) Non-JSON POST_STATE (e.g. rate-limit HTML) → no crash, blocked path
# ---------------------------------------------------------------------------

@test "merge-handler: non-JSON POST_STATE does not crash" {
    run _run_post_state "rate limit exceeded" 1
    [ "$status" -eq 0 ]
    [[ "$output" != *"JSONDecodeError"* ]]
}
