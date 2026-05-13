#!/usr/bin/env bats
# tests/reconciler-dup-prs.bats — covers reconcile_duplicate_prs in
# scanner/reconciler.sh (issue #354). Verifies operator-preference selection
# and external-contributor PR skip behavior.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export ALLOWED_AUTHORS="svv2014"

    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    backend_list_open_prs_raw() { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_close_pr()          { echo "close_pr $2"        >> "$OPS_LOG"; }
    backend_comment_pr()        { echo "comment_pr $2"      >> "$OPS_LOG"; }
    loop_notify()               { echo "notify: $1"         >> "$OPS_LOG"; }
    log() { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$OPS_LOG"
}

@test "dup PRs: operator-authored kept over bot when both close same issue" {
    # PR 100 by bot (newer number), PR 50 by operator (older number).
    # Old logic would keep 100 because it has the higher number.
    # New logic must keep 50 because operator outranks bot.
    export MOCK_PRS_JSON='[
        {"number":50,"body":"closes #1","createdAt":"2026-01-01","title":"op fix","author":"svv2014"},
        {"number":100,"body":"closes #1","createdAt":"2026-01-02","title":"bot fix","author":"some-bot[bot]"}
    ]'

    run reconcile_duplicate_prs "$REPO"
    [ "$status" -eq 0 ]

    grep -q "close_pr 100" "$OPS_LOG"
    ! grep -q "close_pr 50" "$OPS_LOG"
}

@test "dup PRs: older operator PR wins over newer operator PR (preserve in-flight)" {
    export MOCK_PRS_JSON='[
        {"number":50,"body":"closes #2","createdAt":"2026-01-01","title":"first","author":"svv2014"},
        {"number":60,"body":"closes #2","createdAt":"2026-01-02","title":"second","author":"svv2014"}
    ]'

    run reconcile_duplicate_prs "$REPO"
    [ "$status" -eq 0 ]

    grep -q "close_pr 60" "$OPS_LOG"
    ! grep -q "close_pr 50" "$OPS_LOG"
}

@test "dup PRs: external-contributor participant SKIPS dedup entirely" {
    # When an external PR is among the duplicates, reconciler must not auto-close
    # anything — operator must triage. Verifies the safety guard for #354.
    export MOCK_PRS_JSON='[
        {"number":50,"body":"closes #3","createdAt":"2026-01-01","title":"op fix","author":"svv2014"},
        {"number":70,"body":"closes #3","createdAt":"2026-01-02","title":"external","author":"random-user"}
    ]'

    run reconcile_duplicate_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "close_pr" "$OPS_LOG"
}

@test "dup PRs: empty ALLOWED_AUTHORS = gating off, falls back to oldest-wins" {
    ALLOWED_AUTHORS=""
    export MOCK_PRS_JSON='[
        {"number":50,"body":"closes #4","createdAt":"2026-01-01","title":"a","author":"anyone"},
        {"number":60,"body":"closes #4","createdAt":"2026-01-02","title":"b","author":"anyone-else"}
    ]'

    run reconcile_duplicate_prs "$REPO"
    [ "$status" -eq 0 ]

    grep -q "close_pr 60" "$OPS_LOG"
    ! grep -q "close_pr 50" "$OPS_LOG"
}

@test "dup PRs: single PR per issue = no-op" {
    export MOCK_PRS_JSON='[
        {"number":50,"body":"closes #5","createdAt":"2026-01-01","title":"solo","author":"svv2014"}
    ]'

    run reconcile_duplicate_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "close_pr" "$OPS_LOG"
}

@test "dup PRs: notification mentions both authors for transparency" {
    export MOCK_PRS_JSON='[
        {"number":50,"body":"closes #6","createdAt":"2026-01-01","title":"op","author":"svv2014"},
        {"number":100,"body":"closes #6","createdAt":"2026-01-02","title":"bot","author":"some-bot[bot]"}
    ]'

    run reconcile_duplicate_prs "$REPO"
    [ "$status" -eq 0 ]

    grep -q "author svv2014" "$OPS_LOG"
    grep -q "author some-bot" "$OPS_LOG"
}
