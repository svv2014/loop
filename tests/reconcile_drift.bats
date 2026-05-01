#!/usr/bin/env bats
# tests/reconcile_drift.bats — unit tests for lib/reconcile_drift.sh.
#
# Backend functions are stubbed so no real GitHub calls are made. Covers:
#   repair: PR has needs-review, issue still has in-dev → relabel issue
#   repair: PR has in-dev, issue still has needs-review → relabel issue
#   ambiguous: PR carries conflicting mapped labels → needs-clarification

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false

    backend_list_open_prs_raw()    { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_list_open_issues_raw() { echo "${MOCK_ISSUES_JSON:-[]}"; }
    backend_remove_label()         { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_add_label()            { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_comment_issue()        { echo "comment_issue $2"   >> "$OPS_LOG"; }
    log()                          { :; }

    export -f backend_list_open_prs_raw backend_list_open_issues_raw \
              backend_remove_label backend_add_label backend_comment_issue log

    # shellcheck source=../lib/reconcile_drift.sh
    source "$REPO_ROOT/lib/reconcile_drift.sh"

    DRIFT_REPAIRED=0
    BLOCKED_REPORTED=0
}

@test "repair: PR needs-review while issue still in-dev → relabel issue to needs-review" {
    export MOCK_PRS_JSON='[{"number":42,"body":"Closes #100","labels":[{"name":"needs-review"}]}]'
    export MOCK_ISSUES_JSON='[{"number":100,"labels":[{"name":"in-dev"}]}]'

    reconcile_drift_run

    [ "$DRIFT_REPAIRED" -eq 1 ]
    [ "$BLOCKED_REPORTED" -eq 0 ]
    grep -qx "remove_label 100 in-dev" "$OPS_LOG"
    grep -qx "add_label 100 needs-review" "$OPS_LOG"
}

@test "repair: PR in-dev (deprecated alias in-rework on PR) while issue lacks any pipeline label → add in-dev" {
    # PR has the deprecated alias 'in-rework' which canonicalises to in-dev.
    # Issue carries no mapped pipeline label (only an unrelated meta label).
    export MOCK_PRS_JSON='[{"number":7,"body":"Resolves #200","labels":[{"name":"in-rework"}]}]'
    export MOCK_ISSUES_JSON='[{"number":200,"labels":[{"name":"p1-high"}]}]'

    reconcile_drift_run

    [ "$DRIFT_REPAIRED" -eq 1 ]
    [ "$BLOCKED_REPORTED" -eq 0 ]
    grep -qx "add_label 200 in-dev" "$OPS_LOG"
    # Nothing to strip — issue had no mapped pipeline label.
    ! grep -q "^remove_label 200" "$OPS_LOG"
}

@test "ambiguous: PR carries needs-review + in-dev simultaneously → needs-clarification on issue" {
    export MOCK_PRS_JSON='[{"number":9,"body":"Fixes #300","labels":[{"name":"needs-review"},{"name":"in-dev"}]}]'
    export MOCK_ISSUES_JSON='[{"number":300,"labels":[{"name":"in-dev"}]}]'

    reconcile_drift_run

    [ "$BLOCKED_REPORTED" -eq 1 ]
    [ "$DRIFT_REPAIRED" -eq 0 ]
    grep -qx "add_label 300 needs-clarification" "$OPS_LOG"
    grep -q "^comment_issue 300" "$OPS_LOG"
}

@test "no-op: issue label already aligned with PR → no mutations" {
    export MOCK_PRS_JSON='[{"number":11,"body":"Closes #400","labels":[{"name":"needs-review"}]}]'
    export MOCK_ISSUES_JSON='[{"number":400,"labels":[{"name":"needs-review"}]}]'

    reconcile_drift_run

    [ "$DRIFT_REPAIRED" -eq 0 ]
    [ "$BLOCKED_REPORTED" -eq 0 ]
    [ ! -s "$OPS_LOG" ]
}

@test "skip: issue carrying needs-clarification is left for human triage" {
    export MOCK_PRS_JSON='[{"number":13,"body":"Closes #500","labels":[{"name":"needs-review"}]}]'
    export MOCK_ISSUES_JSON='[{"number":500,"labels":[{"name":"in-dev"},{"name":"needs-clarification"}]}]'

    reconcile_drift_run

    [ "$DRIFT_REPAIRED" -eq 0 ]
    [ "$BLOCKED_REPORTED" -eq 0 ]
    [ ! -s "$OPS_LOG" ]
}

@test "dry-run: counters advance but no mutations happen" {
    export DRY_RUN=true
    export MOCK_PRS_JSON='[{"number":15,"body":"Closes #600","labels":[{"name":"needs-review"}]}]'
    export MOCK_ISSUES_JSON='[{"number":600,"labels":[{"name":"in-dev"}]}]'

    reconcile_drift_run

    [ "$DRIFT_REPAIRED" -eq 1 ]
    [ ! -s "$OPS_LOG" ]
}
