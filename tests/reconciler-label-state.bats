#!/usr/bin/env bats
# tests/reconciler-label-state.bats — unit tests for
# reconcile_label_consistency in scanner/reconciler.sh.
# Sources reconciler.sh in lib-only mode and exercises the sweep with
# stubbed backend label ops and a mocked `gh` for issue listing.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOOP_MONITOR_URL=""
    export SLUG="test-slug"

    export MOCK_PRS_JSON='[]'
    export MOCK_ISSUES_JSON='[]'

    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
    printf '%s\n' "${MOCK_ISSUES_JSON:-[]}"
    exit 0
fi
exit 0
GHEOF
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    backend_list_open_prs_raw() { printf '%s\n' "${MOCK_PRS_JSON:-[]}"; }
    backend_add_label()    { echo "add $2 $3" >> "$OPS_LOG"; }
    backend_remove_label() { echo "remove $2 $3" >> "$OPS_LOG"; }
    _loop_emit_event()     { echo "emit $1 $2" >> "$OPS_LOG"; }
    log()                  { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" "$OPS_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# PR rule: qa-pass strips conflicting rework/review labels
# ---------------------------------------------------------------------------

@test "PR qa-pass + needs-dev: needs-dev is stripped" {
    export MOCK_PRS_JSON='[{
        "number": 11,
        "labels": [{"name":"qa-pass"},{"name":"needs-dev"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "remove 11 needs-dev" "$OPS_LOG"
    ! grep -q "add 11 " "$OPS_LOG"
    grep -q "emit label_state_converged" "$OPS_LOG"
}

@test "PR qa-pass alone: no-op" {
    export MOCK_PRS_JSON='[{"number":12,"labels":[{"name":"qa-pass"}]}]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    [ ! -s "$OPS_LOG" ] || ! grep -qE "^(add|remove) 12 " "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# PR rule: qa-fail / changes-requested ensure needs-rework, strip qa-pass/needs-review
# ---------------------------------------------------------------------------

@test "PR qa-fail without needs-rework: needs-rework added" {
    export MOCK_PRS_JSON='[{"number":21,"labels":[{"name":"qa-fail"}]}]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 21 needs-rework" "$OPS_LOG"
}

@test "PR changes-requested + needs-review: needs-rework added, needs-review removed" {
    export MOCK_PRS_JSON='[{
        "number": 22,
        "labels": [{"name":"changes-requested"},{"name":"needs-review"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 22 needs-rework" "$OPS_LOG"
    grep -q "remove 22 needs-review" "$OPS_LOG"
}

@test "PR qa-fail already has needs-rework: no add" {
    export MOCK_PRS_JSON='[{
        "number": 23,
        "labels": [{"name":"qa-fail"},{"name":"needs-rework"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    ! grep -q "add 23 " "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# PR rule: needs-review conflicts with rework signals → drop needs-review
# ---------------------------------------------------------------------------

@test "PR needs-review + needs-dev: needs-review stripped" {
    export MOCK_PRS_JSON='[{
        "number": 31,
        "labels": [{"name":"needs-review"},{"name":"needs-dev"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "remove 31 needs-review" "$OPS_LOG"
}

@test "PR needs-review alone: no-op" {
    export MOCK_PRS_JSON='[{"number":32,"labels":[{"name":"needs-review"}]}]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    [ ! -s "$OPS_LOG" ] || ! grep -qE "^(add|remove) 32 " "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# PR rule: ready-for-qa strips needs-review / needs-dev
# ---------------------------------------------------------------------------

@test "PR ready-for-qa + needs-review + needs-dev: both stripped" {
    export MOCK_PRS_JSON='[{
        "number": 41,
        "labels": [{"name":"ready-for-qa"},{"name":"needs-review"},{"name":"needs-dev"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "remove 41 needs-review" "$OPS_LOG"
    grep -q "remove 41 needs-dev" "$OPS_LOG"
}

@test "PR ready-for-qa alone: no-op" {
    export MOCK_PRS_JSON='[{"number":42,"labels":[{"name":"ready-for-qa"}]}]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    [ ! -s "$OPS_LOG" ] || ! grep -qE "^(add|remove) 42 " "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Issue rules
# ---------------------------------------------------------------------------

@test "issue needs-dev + needs-po: needs-po stripped" {
    export MOCK_ISSUES_JSON='[{
        "number": 51,
        "labels": [{"name":"needs-dev"},{"name":"needs-po"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "remove 51 needs-po" "$OPS_LOG"
}

@test "issue needs-po + in-progress: in-progress stripped" {
    export MOCK_ISSUES_JSON='[{
        "number": 52,
        "labels": [{"name":"needs-po"},{"name":"in-progress"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "remove 52 in-progress" "$OPS_LOG"
}

@test "issue blocked: all triggers stripped" {
    export MOCK_ISSUES_JSON='[{
        "number": 53,
        "labels": [{"name":"blocked"},{"name":"needs-po"},{"name":"needs-dev"},{"name":"in-progress"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "remove 53 needs-po" "$OPS_LOG"
    grep -q "remove 53 needs-dev" "$OPS_LOG"
    grep -q "remove 53 in-progress" "$OPS_LOG"
    ! grep -q "remove 53 blocked" "$OPS_LOG"
}

@test "issue needs-dev alone: no-op" {
    export MOCK_ISSUES_JSON='[{"number":54,"labels":[{"name":"needs-dev"}]}]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    [ ! -s "$OPS_LOG" ] || ! grep -qE "^(add|remove) 54 " "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Env switches
# ---------------------------------------------------------------------------

@test "LOOP_LABEL_CONVERGE=false disables the sweep" {
    export LOOP_LABEL_CONVERGE=false
    export MOCK_PRS_JSON='[{
        "number": 61,
        "labels": [{"name":"qa-pass"},{"name":"needs-dev"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    [ ! -f "$OPS_LOG" ] || [ ! -s "$OPS_LOG" ]
}

@test "DRY_RUN logs but does not mutate" {
    export DRY_RUN=true
    export MOCK_PRS_JSON='[{
        "number": 71,
        "labels": [{"name":"qa-pass"},{"name":"needs-dev"}]
    }]'
    run reconcile_label_consistency "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    [ ! -f "$OPS_LOG" ] || ! grep -qE "^(add|remove|emit) " "$OPS_LOG"
}
