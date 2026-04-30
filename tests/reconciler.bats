#!/usr/bin/env bats
# tests/reconciler.bats — unit tests for lib/recovery.sh helpers.
#
# Backend functions and gh are stubbed as shell functions so no real GitHub
# calls are made. Covers:
#   recovery_check_dependencies — unblock when declared deps are merged
#   recovery_check_stuck_labels — strip timed-out operational labels
#   recovery_prune_orphan_worktrees — remove orphan worktrees

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
    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    # Globals needed by recovery functions.
    export REPO="owner/test-repo"
    export ROOT="$BATS_TMPDIR/fake-root"
    export DRY_RUN=false
    export HANDLER_TIMEOUT=3600
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    export LOOP_LOCK_DIR="$BATS_TMPDIR/locks"
    mkdir -p "$LOOP_LOG_DIR" "$LOOP_LOCK_DIR"

    # Stub backend functions.
    # backend_list_open_issues_raw honours GH_MOCK_ISSUES or MOCK_ISSUES_JSON
    backend_list_open_issues_raw() { echo "${GH_MOCK_ISSUES:-${MOCK_ISSUES_JSON:-[]}}"; }
    backend_list_open_prs_raw()    { echo "${MOCK_PRS_JSON:-[]}"; }
    backend_remove_label()         { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_add_label()            { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_comment_issue()        { echo "comment_issue $2"   >> "$OPS_LOG"; }
    backend_comment_pr()           { echo "comment_pr $2"      >> "$OPS_LOG"; }
    backend_find_pr_for_issue()    { echo "${GH_MOCK_PR_NUM:-}"; }

    # Stub gh: returns state based on GH_STATE_MAP entries "num:STATE num:STATE ...".
    gh() {
        local num state
        num="$3"
        state="UNKNOWN"
        local pair
        for pair in ${GH_STATE_MAP:-}; do
            if [ "${pair%%:*}" = "$num" ]; then
                state="${pair#*:}"
                break
            fi
        done
        echo "$state"
        return 0
    }

    # Stub loop_notify and log so they don't write to disk.
    loop_notify() { :; }
    log()         { :; }

    # Source recovery.sh after stubs are in place.
    # shellcheck source=../lib/recovery.sh
    source "$REPO_ROOT/lib/recovery.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/fixture.yaml" "$BATS_TMPDIR/ops.log" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/locks" \
           "$BATS_TMPDIR/fake-root" 2>/dev/null || true
    rm -rf /tmp/loop-worktree-bats-test-* 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# recovery_check_stuck_labels
# ---------------------------------------------------------------------------

@test "recovery_check_stuck_labels: skips issues updated within timeout" {
    # updatedAt = now (0 seconds old) — must NOT be stripped
    local now_iso
    now_iso=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    export GH_MOCK_ISSUES="[{\"number\":1,\"title\":\"fresh issue\",\"updatedAt\":\"${now_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"

    run recovery_check_stuck_labels "test-proj"
    [ "$status" -eq 0 ]
    # No label operations should have occurred
    [ ! -f "$BATS_TMPDIR/ops.log" ] || ! grep -q "remove_label" "$BATS_TMPDIR/ops.log"
}

@test "recovery_check_stuck_labels: strips stuck in-progress and restores dev" {
    # updatedAt = 2 hours ago (> HANDLER_TIMEOUT * 1.5 = 5400s)
    local old_iso
    old_iso=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    export GH_MOCK_ISSUES="[{\"number\":42,\"title\":\"stuck issue\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"

    # No lock file → handler not alive
    run recovery_check_stuck_labels "test-proj"
    [ "$status" -eq 0 ]
    grep -q "remove_label 42 in-progress" "$BATS_TMPDIR/ops.log"
    grep -q "add_label 42 dev"            "$BATS_TMPDIR/ops.log"
}

@test "recovery_check_stuck_labels: skips issue with live handler lock" {
    local old_iso
    old_iso=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    export GH_MOCK_ISSUES="[{\"number\":7,\"title\":\"live handler issue\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"

    # Write a lock file for this issue with our own PID (process is alive)
    echo "$$" > "$LOOP_LOCK_DIR/test-proj-issue-7.lock"

    run recovery_check_stuck_labels "test-proj"
    [ "$status" -eq 0 ]
    # No label operations should occur when handler is alive
    [ ! -f "$BATS_TMPDIR/ops.log" ] || ! grep -q "remove_label" "$BATS_TMPDIR/ops.log"
}

@test "recovery_check_stuck_labels: strips stuck in-rework and restores needs-rework" {
    local old_iso
    old_iso=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=3)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")

    # Return in-rework issue only for that label query, empty for the others
    backend_list_open_issues_raw() {
        local _repo="$1" lbl="$2"
        if [ "$lbl" = "in-rework" ]; then
            echo "[{\"number\":55,\"title\":\"rework stuck\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-rework\"}]}]"
        else
            echo "[]"
        fi
    }

    run recovery_check_stuck_labels "test-proj"
    [ "$status" -eq 0 ]
    grep -q "remove_label 55 in-rework"   "$BATS_TMPDIR/ops.log"
    grep -q "add_label 55 needs-rework"   "$BATS_TMPDIR/ops.log"
}

@test "recovery_check_stuck_labels: dry-run suppresses label mutations" {
    local old_iso
    old_iso=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    export GH_MOCK_ISSUES="[{\"number\":99,\"title\":\"dry run issue\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"
    DRY_RUN=true

    run recovery_check_stuck_labels "test-proj"
    [ "$status" -eq 0 ]
    # No label operations should occur in dry-run mode
    [ ! -f "$BATS_TMPDIR/ops.log" ] || ! grep -q "remove_label" "$BATS_TMPDIR/ops.log"
}

# ---------------------------------------------------------------------------
# recovery_prune_orphan_worktrees
# ---------------------------------------------------------------------------

@test "recovery_prune_orphan_worktrees: removes orphan dir with no handler and no open PR" {
    local wt_dir="/tmp/loop-worktree-bats-test-123"
    mkdir -p "$wt_dir"
    # Make it old enough to exceed the grace window
    python3 -c "import os; os.utime('$wt_dir', (0, 0))"

    # backend_find_pr_for_issue returns empty → no open PR
    export GH_MOCK_PR_NUM=""

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    [ ! -d "$wt_dir" ]
}

@test "recovery_prune_orphan_worktrees: skips dir with open PR" {
    local wt_dir="/tmp/loop-worktree-bats-test-456"
    mkdir -p "$wt_dir"
    python3 -c "import os; os.utime('$wt_dir', (0, 0))"

    # backend_find_pr_for_issue returns a PR number → open PR exists
    # REPO must be set so the function actually calls backend_find_pr_for_issue
    export REPO="owner/test-repo"
    export GH_MOCK_PR_NUM="10"

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    [ -d "$wt_dir" ]
    rm -rf "$wt_dir"
}

@test "recovery_prune_orphan_worktrees: skips recently modified dir" {
    local wt_dir="/tmp/loop-worktree-bats-test-789"
    mkdir -p "$wt_dir"
    # Do NOT touch mtime — it's fresh (just created = now)

    export GH_MOCK_PR_NUM=""

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    # Dir must still exist (within grace window)
    [ -d "$wt_dir" ]
    rm -rf "$wt_dir"
}

@test "recovery_prune_orphan_worktrees: skips dir with live handler lock" {
    local wt_dir="/tmp/loop-worktree-bats-test-321"
    mkdir -p "$wt_dir"
    python3 -c "import os; os.utime('$wt_dir', (0, 0))"

    # Write a live lock for issue 321 using our own PID
    echo "$$" > "$LOOP_LOCK_DIR/proj-321.lock"

    export GH_MOCK_PR_NUM=""

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    # Dir must survive because handler is alive
    [ -d "$wt_dir" ]
    rm -rf "$wt_dir"
}

@test "recovery_prune_orphan_worktrees: dry-run does not remove dir" {
    local wt_dir="/tmp/loop-worktree-bats-test-999"
    mkdir -p "$wt_dir"
    python3 -c "import os; os.utime('$wt_dir', (0, 0))"

    export GH_MOCK_PR_NUM=""
    DRY_RUN=true

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    # Dir must survive in dry-run
    [ -d "$wt_dir" ]
    rm -rf "$wt_dir"
}

# ---------------------------------------------------------------------------
# recovery_gc_stale_worktrees — TTL-based GC of worktree dirs
#
# Tests scope the scan glob to $BATS_TMPDIR/loop-worktree-gc-* via
# LOOP_WORKTREE_GC_GLOB so they never touch real /tmp/loop-worktree-*
# directories owned by live handlers.
# ---------------------------------------------------------------------------

@test "recovery_gc_stale_worktrees: respects TTL — fresh dir is spared" {
    local sandbox="$BATS_TMPDIR/gc-ttl-fresh"
    rm -rf "$sandbox"; mkdir -p "$sandbox/loop-worktree-fresh"
    export LOOP_WORKTREE_GC_GLOB="$sandbox/loop-worktree-*"
    export LOOP_WORKTREE_TTL=21600

    run recovery_gc_stale_worktrees
    [ "$status" -eq 0 ]
    local last_idx=$(( ${#lines[@]} - 1 ))
    [ "${lines[$last_idx]}" = "0" ]
    [ -d "$sandbox/loop-worktree-fresh" ]
    rm -rf "$sandbox"
    unset LOOP_WORKTREE_GC_GLOB LOOP_WORKTREE_TTL
}

@test "recovery_gc_stale_worktrees: removes stale dir past TTL" {
    local sandbox="$BATS_TMPDIR/gc-ttl-stale"
    rm -rf "$sandbox"; mkdir -p "$sandbox/loop-worktree-stale"
    python3 -c "import os; os.utime('$sandbox/loop-worktree-stale', (0, 0))"
    export LOOP_WORKTREE_GC_GLOB="$sandbox/loop-worktree-*"
    export LOOP_WORKTREE_TTL=1

    run recovery_gc_stale_worktrees
    [ "$status" -eq 0 ]
    local last_idx=$(( ${#lines[@]} - 1 ))
    [ "${lines[$last_idx]}" = "1" ]
    [ ! -d "$sandbox/loop-worktree-stale" ]
    rm -rf "$sandbox"
    unset LOOP_WORKTREE_GC_GLOB LOOP_WORKTREE_TTL
}

@test "recovery_gc_stale_worktrees: spares dir with live PID owner" {
    local sandbox="$BATS_TMPDIR/gc-live-owner"
    rm -rf "$sandbox"; mkdir -p "$sandbox/loop-worktree-live"
    python3 -c "import os; os.utime('$sandbox/loop-worktree-live', (0, 0))"
    export LOOP_WORKTREE_GC_GLOB="$sandbox/loop-worktree-*"
    export LOOP_WORKTREE_TTL=1

    # Stub the owner-probe to claim a live process holds the dir.
    _recovery_worktree_has_live_owner() { return 0; }

    run recovery_gc_stale_worktrees
    [ "$status" -eq 0 ]
    local last_idx=$(( ${#lines[@]} - 1 ))
    [ "${lines[$last_idx]}" = "0" ]
    [ -d "$sandbox/loop-worktree-live" ]
    rm -rf "$sandbox"
    unset LOOP_WORKTREE_GC_GLOB LOOP_WORKTREE_TTL
}
