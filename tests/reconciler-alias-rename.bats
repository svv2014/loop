#!/usr/bin/env bats
# tests/reconciler-alias-rename.bats — covers reconcile_alias_renames in
# scanner/reconciler.sh (issue #168). Sources reconciler.sh in lib-only mode so
# the main run is skipped, then exercises the function with stubbed backends.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false

    # Stubs must exist before sourcing reconciler.sh so subsequent function
    # definitions inside the script don't shadow them. The script's own
    # `backend_*` and `log` definitions live in libs we override after source.
    LOOP_RECONCILER_LIB_ONLY=1
    # Clear positional args — reconciler.sh has an arg parser at the top.
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Now override library functions with test stubs.
    backend_list_open_prs_raw() { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_list_open_issues_raw() {
        local _repo="$1" lbl="$2"
        local var="MOCK_ISSUES_${lbl//-/_}"
        eval "echo \"\${$var:-[]}\""
    }
    # _reconcile_label_renames calls backend_list_issues_with_label and
    # backend_list_prs_with_label (NDJSON: one object per line).
    # Both must filter by the requested label so canonical tickets are untouched.
    backend_list_issues_with_label() {
        local _repo="$1" lbl="$2"
        local var="MOCK_ISSUES_${lbl//-/_}"
        local arr; eval "arr=\"\${$var:-[]}\""
        echo "$arr" | jq -c '.[]' 2>/dev/null || true
    }
    backend_list_prs_with_label() {
        local _repo="$1" lbl="$2"
        echo "${MOCK_PRS_JSON:-[]}" | \
            jq -c --arg lbl "$lbl" '.[] | select(.labels[] | .name == $lbl)' 2>/dev/null || true
    }
    backend_add_label()    { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_remove_label() { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    log() { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$OPS_LOG" "$BATS_TMPDIR/log.out"
}

@test "reconcile_alias_renames: deprecated issue label → adds canonical, then removes alias" {
    export MOCK_ISSUES_dev='[{"number":11,"labels":[{"name":"dev"}]}]'
    export MOCK_PRS_JSON='[]'

    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]

    grep -q "add_label 11 needs-dev" "$OPS_LOG"
    grep -q "remove_label 11 dev"    "$OPS_LOG"

    # Additive precedes subtractive (never lossy).
    local add_line rm_line
    add_line=$(grep -n "add_label 11 needs-dev" "$OPS_LOG" | head -1 | cut -d: -f1)
    rm_line=$(grep -n  "remove_label 11 dev"    "$OPS_LOG" | head -1 | cut -d: -f1)
    [ "$add_line" -lt "$rm_line" ]
}

@test "reconcile_alias_renames: deprecated PR label → adds canonical, removes alias" {
    export MOCK_PRS_JSON='[{"number":42,"labels":[{"name":"review-pending"}]}]'

    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]

    grep -q "add_label 42 needs-review"      "$OPS_LOG"
    grep -q "remove_label 42 review-pending" "$OPS_LOG"
}

@test "reconcile_alias_renames: ticket already canonical is untouched" {
    # Only canonical labels present; alias-keyed issue queries return [].
    export MOCK_PRS_JSON='[{"number":21,"labels":[{"name":"needs-review"}]}]'

    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label"    "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

@test "reconcile_alias_renames: idempotent — second pass on clean repo is a no-op" {
    export MOCK_PRS_JSON='[{"number":21,"labels":[{"name":"needs-review"}]}]'

    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]
    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label"    "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

@test "reconcile_alias_renames: emits alias_renamed=N counter to log" {
    export MOCK_ISSUES_dev='[{"number":11,"labels":[{"name":"dev"}]}]'
    export MOCK_PRS_JSON='[{"number":42,"labels":[{"name":"review-pending"}]}]'

    log() { echo "$*" >> "$BATS_TMPDIR/log.out"; }
    rm -f "$BATS_TMPDIR/log.out"

    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]
    grep -q "alias_renamed=2" "$BATS_TMPDIR/log.out"
}

@test "reconcile_alias_renames: DRY_RUN performs no label mutations" {
    export MOCK_ISSUES_dev='[{"number":11,"labels":[{"name":"dev"}]}]'
    export MOCK_PRS_JSON='[]'
    export DRY_RUN=true

    run reconcile_alias_renames "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label"    "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}
