#!/usr/bin/env bats
# tests/reconciler.bats — unit tests for lib/recovery.sh helpers.
#
# Tests are self-contained: gh, backend_*, loop_label_for, loop_notify, and log
# are all stubbed so no real GitHub or filesystem state is needed.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOCK_DIR="$BATS_TMPDIR/locks"
    mkdir -p "$LOOP_LOCK_DIR"

    # Set required globals that recovery.sh functions depend on.
    export LOOP_ROOT="$REPO_ROOT"
    export REPO="owner/test-repo"
    export ROOT="$BATS_TMPDIR/fake-root"
    export DRY_RUN=false
    export HANDLER_TIMEOUT=3600

    # Stub library functions so we can source recovery.sh in isolation.
    loop_label_for()             { echo "$2"; }
    loop_notify()                { :; }
    log()                        { :; }
    backend_list_open_issues_raw() { echo "${GH_MOCK_OUTPUT:-[]}"; }
    backend_remove_label()       { echo "remove_label $3" >> "$BATS_TMPDIR/ops.log"; }
    backend_add_label()          { echo "add_label $3"    >> "$BATS_TMPDIR/ops.log"; }

    # Source only recovery.sh (it does not call acquire_lock on source).
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/recovery.sh"

    rm -f "$BATS_TMPDIR/ops.log"
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/locks" "$BATS_TMPDIR/ops.log" \
           "$BATS_TMPDIR/fake-root" 2>/dev/null || true
    # Clean up any worktree dirs created during tests
    rm -rf /tmp/loop-worktree-bats-test-* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# recovery_check_stuck_labels
# ---------------------------------------------------------------------------

@test "recovery_check_stuck_labels: skips issues updated within timeout" {
    # updatedAt = now (0 seconds old) — must NOT be stripped
    local now_iso
    now_iso=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    export GH_MOCK_OUTPUT="[{\"number\":1,\"title\":\"fresh issue\",\"updatedAt\":\"${now_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"

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
    export GH_MOCK_OUTPUT="[{\"number\":42,\"title\":\"stuck issue\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"

    # No lock file → handler not alive
    run recovery_check_stuck_labels "test-proj"
    [ "$status" -eq 0 ]
    grep -q "remove_label in-progress" "$BATS_TMPDIR/ops.log"
    grep -q "add_label dev"            "$BATS_TMPDIR/ops.log"
}

@test "recovery_check_stuck_labels: skips issue with live handler lock" {
    local old_iso
    old_iso=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    export GH_MOCK_OUTPUT="[{\"number\":7,\"title\":\"live handler issue\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"

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

    # Override backend stub to return in-rework issue only for that label query
    local call_count=0
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
    grep -q "remove_label in-rework"   "$BATS_TMPDIR/ops.log"
    grep -q "add_label needs-rework"   "$BATS_TMPDIR/ops.log"
}

@test "recovery_check_stuck_labels: dry-run suppresses label mutations" {
    local old_iso
    old_iso=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    export GH_MOCK_OUTPUT="[{\"number\":99,\"title\":\"dry run issue\",\"updatedAt\":\"${old_iso}\",\"labels\":[{\"name\":\"in-progress\"}]}]"
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
    # Make it old enough to exceed the grace window (touch mtime to epoch-ish)
    python3 -c "import os; os.utime('$wt_dir', (0, 0))"

    # gh returns 0 open PRs for issue 123
    export GH_MOCK_OUTPUT="0"

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    [ ! -d "$wt_dir" ]
}

@test "recovery_prune_orphan_worktrees: skips dir with open PR" {
    local wt_dir="/tmp/loop-worktree-bats-test-456"
    mkdir -p "$wt_dir"
    python3 -c "import os; os.utime('$wt_dir', (0, 0))"

    # Mock gh to return 1 open PR (jq output of the count query)
    export GH_MOCK_OUTPUT="1"

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    [ -d "$wt_dir" ]
    rm -rf "$wt_dir"
}

@test "recovery_prune_orphan_worktrees: skips recently modified dir" {
    local wt_dir="/tmp/loop-worktree-bats-test-789"
    mkdir -p "$wt_dir"
    # Do NOT touch mtime — it's fresh (just created = now)

    export GH_MOCK_OUTPUT="0"

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

    # Write a live lock for issue 321
    echo "$$" > "$LOOP_LOCK_DIR/proj-321.lock"

    export GH_MOCK_OUTPUT="0"

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

    export GH_MOCK_OUTPUT="0"
    DRY_RUN=true

    run recovery_prune_orphan_worktrees
    [ "$status" -eq 0 ]
    # Dir must survive in dry-run
    [ -d "$wt_dir" ]
    rm -rf "$wt_dir"
}
