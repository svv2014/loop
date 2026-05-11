#!/usr/bin/env bats
# tests/reconciler-ci-green.bats — unit tests for reconcile_ci_green_prs in
# scanner/reconciler.sh (issue #280). Sources reconciler.sh in lib-only mode
# so the main run is skipped, then exercises the function with stubbed
# backends.
#
# Covers:
#   - All required checks SUCCESS + needs-dev → needs-review added, needs-dev removed
#   - A required check PENDING → no-op
#   - PR already has needs-review → no-op
#   - PR has a human CHANGES_REQUESTED review → no-op
#   - AUTO_PROMOTE_ON_CI=false → no-op
#   - PR does not have needs-dev → no-op
#   - Non-loop branch PR → no-op
#   - DRY_RUN → no mutations

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export AUTO_PROMOTE_ON_CI=true
    export LOOP_BRANCH_PREFIX="feat/issue-"
    export LOOP_MONITOR_URL=""
    export ALLOWED_AUTHORS=""

    # Source reconciler in lib-only mode so only functions are defined.
    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Default: no loop-opened PRs.
    backend_list_open_prs_raw() { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_add_label()         { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_remove_label()      { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_pr_view()           { echo "${MOCK_PR_DETAIL}"; }

    loop_stage_trigger()        { echo "needs-review"; }
    loop_notify()               { :; }
    log()                       { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 1: all required checks SUCCESS + needs-dev → promote to needs-review
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: SUCCESS checks + needs-dev → needs-review added" {
    export MOCK_PRS_JSON='[{
        "number": 101,
        "headRefName": "feat/issue-42-add-login",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #42",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true},
            {"name":"web","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    grep -q "add_label 101 needs-review" "$OPS_LOG"
}

@test "reconcile_ci_green_prs: SUCCESS checks + needs-dev → needs-dev removed" {
    export MOCK_PRS_JSON='[{
        "number": 101,
        "headRefName": "feat/issue-42-add-login",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #42",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true},
            {"name":"web","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    grep -q "remove_label 101 needs-dev" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 2: a required check PENDING → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: PENDING required check → no mutations" {
    export MOCK_PRS_JSON='[{
        "number": 102,
        "headRefName": "feat/issue-55-fix-nav",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #55",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"PENDING","isRequired":true},
            {"name":"web","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 3: PR already has needs-review → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: PR already has needs-review → no-op" {
    export MOCK_PRS_JSON='[{
        "number": 103,
        "headRefName": "feat/issue-66-auth",
        "labels": [{"name":"needs-dev"},{"name":"needs-review"}],
        "body": "Closes #66",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"},{"name":"needs-review"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 4: PR has a human CHANGES_REQUESTED review → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: human CHANGES_REQUESTED review → no-op" {
    export MOCK_PRS_JSON='[{
        "number": 104,
        "headRefName": "feat/issue-77-cache",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #77",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"}],
        "latestReviews": [
            {"state":"CHANGES_REQUESTED","author":{"login":"human-reviewer"}}
        ],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 5: AUTO_PROMOTE_ON_CI=false → skip entirely
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: AUTO_PROMOTE_ON_CI=false → no-op" {
    export AUTO_PROMOTE_ON_CI=false
    export MOCK_PRS_JSON='[{
        "number": 105,
        "headRefName": "feat/issue-88-perf",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #88",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 6: PR lacks needs-dev → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: PR without needs-dev → no-op" {
    export MOCK_PRS_JSON='[{
        "number": 106,
        "headRefName": "feat/issue-99-signup",
        "labels": [{"name":"in-progress"}],
        "body": "Closes #99",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"in-progress"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 7: non-loop branch PR → ignored
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: non-loop branch PR is ignored" {
    export MOCK_PRS_JSON='[{
        "number": 107,
        "headRefName": "hotfix/login-crash",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #10",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 8: DRY_RUN → no mutations despite green CI
# ---------------------------------------------------------------------------

@test "reconcile_ci_green_prs: DRY_RUN performs no mutations" {
    export DRY_RUN=true
    export MOCK_PRS_JSON='[{
        "number": 108,
        "headRefName": "feat/issue-20-signup",
        "labels": [{"name":"needs-dev"}],
        "body": "Closes #20",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_DETAIL='{
        "labels": [{"name":"needs-dev"}],
        "latestReviews": [],
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [
            {"name":"lint","state":"SUCCESS","isRequired":true}
        ]
    }'

    run reconcile_ci_green_prs "$REPO" "test-slug"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}
