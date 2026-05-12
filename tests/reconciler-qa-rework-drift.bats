#!/usr/bin/env bats
# tests/reconciler-qa-rework-drift.bats — regression for loop#315.
# Verifies reconcile_qa_rework_label_drift strips stale needs-qa from PRs
# that carry both a qa label and a rework trigger label simultaneously.

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
    log() { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: PR with needs-qa + in-rework gets needs-qa stripped" {
    export MOCK_PRS_JSON='[{"number":100,"labels":[{"name":"needs-qa"},{"name":"in-rework"}]}]'

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove_label 100 needs-qa" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: PR with ready-for-qa (alias) + needs-dev gets it stripped" {
    export MOCK_PRS_JSON='[{"number":101,"labels":[{"name":"ready-for-qa"},{"name":"needs-dev"}]}]'

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove_label 101 ready-for-qa" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: PR with needs-qa + needs-rework gets needs-qa stripped" {
    export MOCK_PRS_JSON='[{"number":102,"labels":[{"name":"needs-qa"},{"name":"needs-rework"}]}]'

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove_label 102 needs-qa" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: PR with only needs-qa (no rework label) is untouched" {
    export MOCK_PRS_JSON='[{"number":103,"labels":[{"name":"needs-qa"}]}]'

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: PR with only in-rework (no qa label) is untouched" {
    export MOCK_PRS_JSON='[{"number":104,"labels":[{"name":"in-rework"}]}]'

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: DRY_RUN performs no mutations" {
    export MOCK_PRS_JSON='[{"number":100,"labels":[{"name":"needs-qa"},{"name":"in-rework"}]}]'
    export DRY_RUN=true

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

@test "reconcile_qa_rework_label_drift: clean PRs produce no ops" {
    export MOCK_PRS_JSON='[{"number":110,"labels":[{"name":"needs-review"}]},{"number":111,"labels":[{"name":"needs-qa"}]}]'

    run reconcile_qa_rework_label_drift "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}
