#!/usr/bin/env bats
# tests/reconciler-pr-label-audit.bats — covers reconcile_pr_label_audit in
# scanner/reconciler.sh (issue #129). Sources reconciler.sh in lib-only mode
# so the main run is skipped, then exercises the function with stubbed
# backends.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false

    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    backend_list_open_prs_raw() { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_remove_label()      { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_comment_pr()        { echo "comment_pr $2 $3"   >> "$OPS_LOG"; }
    log() { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$OPS_LOG"
}

@test "reconcile_pr_label_audit: PR with only stage labels is untouched" {
    export MOCK_PRS_JSON='[{"number":50,"labels":[{"name":"needs-review"}]},{"number":51,"labels":[{"name":"in-review"}]}]'

    run reconcile_pr_label_audit "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "comment_pr"   "$OPS_LOG"
}

@test "reconcile_pr_label_audit: PR carrying tracker is stripped with a comment" {
    export MOCK_PRS_JSON='[{"number":75,"labels":[{"name":"needs-review"},{"name":"tracker"}]}]'

    run reconcile_pr_label_audit "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove_label 75 tracker" "$OPS_LOG"
    grep -q "comment_pr 75"           "$OPS_LOG"
    grep -q "issue-only label(s): tracker" "$OPS_LOG"
}

@test "reconcile_pr_label_audit: PR with two issue-only labels gets one combined comment" {
    export MOCK_PRS_JSON='[{"number":80,"labels":[{"name":"dev"},{"name":"epic"}]}]'

    run reconcile_pr_label_audit "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove_label 80 dev"  "$OPS_LOG"
    grep -q "remove_label 80 epic" "$OPS_LOG"

    # Exactly one comment, listing both labels (sorted).
    local comments
    comments=$(grep -c "^comment_pr 80" "$OPS_LOG")
    [ "$comments" -eq 1 ]
    grep -q "issue-only label(s): dev,epic" "$OPS_LOG"
}

@test "reconcile_pr_label_audit: idempotent — clean PR set produces no ops" {
    export MOCK_PRS_JSON='[{"number":90,"labels":[{"name":"needs-review"}]}]'

    run reconcile_pr_label_audit "$REPO"
    [ "$status" -eq 0 ]
    run reconcile_pr_label_audit "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "comment_pr"   "$OPS_LOG"
}

@test "reconcile_pr_label_audit: DRY_RUN performs no mutations" {
    export MOCK_PRS_JSON='[{"number":75,"labels":[{"name":"tracker"}]}]'
    export DRY_RUN=true

    run reconcile_pr_label_audit "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "comment_pr"   "$OPS_LOG"
}
