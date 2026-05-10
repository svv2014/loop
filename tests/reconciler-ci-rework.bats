#!/usr/bin/env bats
# tests/reconciler-ci-rework.bats — unit tests for reconcile_ci_red_prs in
# scanner/reconciler.sh (issue #268). Sources reconciler.sh in lib-only mode
# so the main run is skipped, then exercises the function with stubbed
# backends and gh.
#
# Covers:
#   - FAILURE on required check → needs-rework applied, trigger stripped
#   - SUCCESS (no failures) → no-op
#   - Already has needs-rework label → no-op
#   - Human review present → no-op
#   - AUTO_REWORK_ON_CI=false → no-op
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
    export AUTO_REWORK_ON_CI=true
    export LOOP_BRANCH_PREFIX="feat/issue-"
    export LOOP_MONITOR_URL=""

    # Source reconciler in lib-only mode so only functions are defined.
    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Default: no loop-opened PRs.
    backend_list_open_prs_raw() { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_add_label()         { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_remove_label()      { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_comment_pr()        { echo "comment_pr $2"      >> "$OPS_LOG"; }

    # gh stub: dispatched for `gh pr view` (reviews) and `gh pr checks`.
    gh() {
        # gh pr view <num> --repo <repo> --json reviews --jq ...
        if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
            echo "${MOCK_REVIEW_COUNT:-0}"
            return 0
        fi
        # gh pr checks <num> --repo <repo> --json name,state,required
        if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
            echo "${MOCK_CHECKS_JSON:-[]}"
            return 0
        fi
        return 0
    }

    loop_notify() { :; }
    log()         { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 1: required check FAILURE → apply needs-rework, strip trigger
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: FAILURE on required check applies needs-rework to PR" {
    export MOCK_PRS_JSON='[{
        "number": 133,
        "headRefName": "feat/issue-42-add-login",
        "labels": [{"name":"needs-review"}],
        "body": "Closes #42",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[
        {"name":"lint","state":"FAILURE","required":true},
        {"name":"build","state":"SUCCESS","required":true}
    ]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    grep -q "add_label 133 needs-rework" "$OPS_LOG"
}

@test "reconcile_ci_red_prs: FAILURE strips trigger labels from parent issue" {
    export MOCK_PRS_JSON='[{
        "number": 133,
        "headRefName": "feat/issue-42-add-login",
        "labels": [{"name":"needs-review"}],
        "body": "Closes #42",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    # At least one trigger label removal on the parent issue (42).
    grep -qE "remove_label 42 (needs-dev|in-dev|dev|in-progress)" "$OPS_LOG"
}

@test "reconcile_ci_red_prs: FAILURE posts a comment on the PR" {
    export MOCK_PRS_JSON='[{
        "number": 133,
        "headRefName": "feat/issue-42-add-login",
        "labels": [],
        "body": "Closes #42",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    grep -q "comment_pr 133" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 2: all checks SUCCESS → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: all checks SUCCESS → no mutations" {
    export MOCK_PRS_JSON='[{
        "number": 134,
        "headRefName": "feat/issue-55-fix-nav",
        "labels": [],
        "body": "Closes #55",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[
        {"name":"lint","state":"SUCCESS","required":true},
        {"name":"build","state":"SUCCESS","required":true}
    ]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 3: PR already has needs-rework → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: PR already has needs-rework → no-op" {
    export MOCK_PRS_JSON='[{
        "number": 200,
        "headRefName": "feat/issue-99-cache",
        "labels": [{"name":"needs-rework"}],
        "body": "Closes #99",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 4: PR has human review → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: human review present → no-op" {
    export MOCK_PRS_JSON='[{
        "number": 201,
        "headRefName": "feat/issue-77-auth",
        "labels": [],
        "body": "Closes #77",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=1
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 5: non-required check FAILURE → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: only non-required check fails → no mutation" {
    export MOCK_PRS_JSON='[{
        "number": 202,
        "headRefName": "feat/issue-88-perf",
        "labels": [],
        "body": "Closes #88",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[
        {"name":"coverage","state":"FAILURE","required":false},
        {"name":"lint","state":"SUCCESS","required":true}
    ]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 6: AUTO_REWORK_ON_CI=false → skip entirely
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: AUTO_REWORK_ON_CI=false → no-op" {
    export AUTO_REWORK_ON_CI=false
    export MOCK_PRS_JSON='[{
        "number": 300,
        "headRefName": "feat/issue-10-login",
        "labels": [],
        "body": "Closes #10",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 7: DRY_RUN → no mutations despite red CI
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: DRY_RUN performs no mutations" {
    export DRY_RUN=true
    export MOCK_PRS_JSON='[{
        "number": 400,
        "headRefName": "feat/issue-20-signup",
        "labels": [],
        "body": "Closes #20",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove_label" "$OPS_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -q "comment_pr" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 8: PR head does not match loop branch convention → no-op
# ---------------------------------------------------------------------------

@test "reconcile_ci_red_prs: non-loop branch PR is ignored" {
    export MOCK_PRS_JSON='[{
        "number": 500,
        "headRefName": "hotfix/login-crash",
        "labels": [],
        "body": "Closes #30",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_REVIEW_COUNT=0
    export MOCK_CHECKS_JSON='[{"name":"lint","state":"FAILURE","required":true}]'

    run reconcile_ci_red_prs "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "add_label" "$OPS_LOG"
}
