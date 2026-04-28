#!/usr/bin/env bats
# tests/reconciler.bats — unit tests for recovery_check_dependencies in lib/recovery.sh.
#
# Backend functions and gh are stubbed as shell functions so no real GitHub
# calls are made. Two scenarios are covered:
#   (1) all declared deps closed  → blocked removed + trigger added + comment posted
#   (2) one dep still open        → no label change, no comment

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"

    # Minimal project config so loop_label_for resolves to "dev".
    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: test-proj
    name: Test Project
    repo: owner/test-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # Source workflow.sh so loop_label_for is available.
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

    # Ops log captures every label/comment call.
    OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    # Stub backend functions.
    backend_list_open_issues_raw() { echo "${MOCK_ISSUES_JSON:-[]}"; }
    backend_list_open_prs_raw()    { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_remove_label()         { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_add_label()            { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_comment_issue()        { echo "comment_issue $2"   >> "$OPS_LOG"; }
    backend_comment_pr()           { echo "comment_pr $2"      >> "$OPS_LOG"; }

    # Stub gh: returns state based on GH_STATE_MAP entries "num:STATE num:STATE ...".
    gh() {
        local cmd="$1" subcmd="$2"  # e.g. "issue" "view"
        local num state
        # Extract number from args (3rd positional arg after "issue view" or "pr view").
        num="$3"
        # Look up in GH_STATE_MAP (space-separated "N:STATE" pairs).
        state="UNKNOWN"
        local pair
        for pair in ${GH_STATE_MAP:-}; do
            if [ "${pair%%:*}" = "$num" ]; then
                state="${pair#*:}"
                break
            fi
        done
        # Honour --jq '.state' output format.
        echo "$state"
        return 0
    }

    # Stub loop_notify and log so they don't write to disk.
    loop_notify() { :; }
    log()         { :; }

    # DRY_RUN=false so mutations are executed.
    DRY_RUN=false

    # REPO must be set (normally exported by loop_load_project).
    export REPO="owner/test-repo"

    # Source recovery.sh after stubs are in place.
    # shellcheck source=../lib/recovery.sh
    source "$REPO_ROOT/lib/recovery.sh"
}

teardown() {
    rm -f "$BATS_TMPDIR/fixture.yaml" "$BATS_TMPDIR/ops.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Scenario 1: all declared dependencies are closed → unblock + restore + comment
# ---------------------------------------------------------------------------

@test "recovery_check_dependencies: all deps closed removes blocked and restores trigger label" {
    # Issue #10 is blocked; its ## Dependencies section references #100 and #101.
    export MOCK_ISSUES_JSON='[{
        "number": 10,
        "title": "Implement feature X",
        "labels": [{"name":"blocked"}],
        "body": "## Summary\nDoes stuff.\n\n## Dependencies\n- #100\n- #101\n\n## Notes\nNone.",
        "updatedAt": "2024-01-01T00:00:00Z"
    }]'
    export MOCK_PRS_JSON='[]'

    # Both deps are closed.
    export GH_STATE_MAP="100:CLOSED 101:CLOSED"

    run recovery_check_dependencies "test-proj"
    [ "$status" -eq 0 ]

    # blocked must be removed.
    grep -q "remove_label 10 blocked" "$OPS_LOG"

    # trigger label (dev) must be added.
    grep -q "add_label 10 dev" "$OPS_LOG"

    # comment must be posted on the issue.
    grep -q "comment_issue 10" "$OPS_LOG"
}

@test "recovery_check_dependencies: all deps closed — remove precedes add" {
    export MOCK_ISSUES_JSON='[{
        "number": 20,
        "title": "Another blocked issue",
        "labels": [{"name":"blocked"}],
        "body": "## Dependencies\n- #200\n",
        "updatedAt": "2024-01-01T00:00:00Z"
    }]'
    export MOCK_PRS_JSON='[]'
    export GH_STATE_MAP="200:CLOSED"

    run recovery_check_dependencies "test-proj"
    [ "$status" -eq 0 ]

    local rm_line add_line
    rm_line=$(grep -n "remove_label 20 blocked" "$OPS_LOG" | cut -d: -f1)
    add_line=$(grep -n "add_label 20 dev"       "$OPS_LOG" | cut -d: -f1)
    [ "$rm_line" -lt "$add_line" ]
}

# ---------------------------------------------------------------------------
# Scenario 2: one or more deps still open → no label change, no comment
# ---------------------------------------------------------------------------

@test "recovery_check_dependencies: one dep open leaves issue unchanged" {
    export MOCK_ISSUES_JSON='[{
        "number": 30,
        "title": "Blocked issue with open dep",
        "labels": [{"name":"blocked"}],
        "body": "## Dependencies\n- #300\n- #301\n",
        "updatedAt": "2024-01-01T00:00:00Z"
    }]'
    export MOCK_PRS_JSON='[]'

    # #300 closed but #301 still open.
    export GH_STATE_MAP="300:CLOSED 301:OPEN"

    run recovery_check_dependencies "test-proj"
    [ "$status" -eq 0 ]

    # No label mutations and no comment.
    [ ! -f "$OPS_LOG" ] || ! grep -q "remove_label 30" "$OPS_LOG"
    [ ! -f "$OPS_LOG" ] || ! grep -q "add_label 30"    "$OPS_LOG"
    [ ! -f "$OPS_LOG" ] || ! grep -q "comment_issue 30" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 3: issue with no ## Dependencies section is skipped silently
# ---------------------------------------------------------------------------

@test "recovery_check_dependencies: issue without Dependencies section is untouched" {
    export MOCK_ISSUES_JSON='[{
        "number": 40,
        "title": "Blocked but no dep section",
        "labels": [{"name":"blocked"}],
        "body": "No special sections here.",
        "updatedAt": "2024-01-01T00:00:00Z"
    }]'
    export MOCK_PRS_JSON='[]'
    export GH_STATE_MAP=""

    run recovery_check_dependencies "test-proj"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || [ ! -s "$OPS_LOG" ]
}

# ---------------------------------------------------------------------------
# Scenario 4: blocked PR with all deps closed → unblock + needs-review + comment
# ---------------------------------------------------------------------------

@test "recovery_check_dependencies: blocked PR with all deps closed restores needs-review" {
    export MOCK_ISSUES_JSON='[]'
    export MOCK_PRS_JSON='[{
        "number": 50,
        "title": "Blocked PR waiting on dep",
        "headRefName": "feat/issue-50",
        "labels": [{"name":"blocked"}],
        "body": "## Dependencies\n- #400\n",
        "createdAt": "2024-01-01T00:00:00Z",
        "updatedAt": "2024-01-01T00:00:00Z"
    }]'
    export GH_STATE_MAP="400:CLOSED"

    run recovery_check_dependencies "test-proj"
    [ "$status" -eq 0 ]

    grep -q "remove_label 50 blocked"   "$OPS_LOG"
    grep -q "add_label 50 needs-review" "$OPS_LOG"
    grep -q "comment_pr 50"             "$OPS_LOG"
}
