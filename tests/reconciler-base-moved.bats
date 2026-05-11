#!/usr/bin/env bats
# tests/reconciler-base-moved.bats — unit tests for reconcile_pr_base_moved
# in scanner/reconciler.sh (issue #281). Sources reconciler.sh in lib-only
# mode so only function definitions are loaded, then exercises the sweep with
# stubbed backends, git, and loop helpers.
#
# Covers:
#   (a) DIRTY PR, clean rebase → push --force-with-lease called, no labels mutated
#   (b) DIRTY PR, rebase conflict → needs-rework applied, comment with file names posted
#   (c) PR already has needs-rework → no-op
#   (d) AUTO_REBASE_ON_BASE_MOVE=false → no-op

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    export GIT_LOG="$BATS_TMPDIR/git.log"
    rm -f "$OPS_LOG" "$GIT_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export AUTO_REBASE_ON_BASE_MOVE=true
    export LOOP_BRANCH_PREFIX="feat/issue-"
    export LOOP_MONITOR_URL=""
    export SLUG="test-slug"

    # Default mock values (set to non-empty defaults to avoid brace-expansion issues).
    export MOCK_PRS_JSON='[]'
    export MOCK_PR_VIEW_JSON='{}'
    export MOCK_REBASE_EXIT=0
    export MOCK_PUSH_EXIT=0
    export MOCK_CONFLICTED_FILES=""
    export MOCK_GIT_LOG_OUTPUT="abc1234 mock commit subject"

    # Suppress LOOP_EXTRA_PATH so lib/env.sh does not prepend /opt/homebrew/bin
    # and shadow the fake git binary we place in $BATS_TMPDIR/bin.
    export LOOP_EXTRA_PATH=""

    # Source reconciler in lib-only mode (before PATH setup so env.sh runs first).
    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Fake git binary: intercepts worktree/fetch/rebase/push/diff/log calls.
    # Must be installed AFTER sourcing (env.sh overwrites PATH) and re-prepended.
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/git" <<'GITEOF'
#!/usr/bin/env bash
echo "git $*" >> "$GIT_LOG"

# Parse: git [-C <dir>]... <subcmd> [args...]
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ] && [ "${args[$i]}" = "-C" ]; do
    i=$(( i + 2 ))  # skip -C and its argument
done
subcmd="${args[$i]:-}"
rest=("${args[@]:$(( i + 1 ))}")
action="${rest[0]:-}"

case "$subcmd" in
    fetch)
        exit 0
        ;;
    worktree)
        case "$action" in
            add)
                # args after "add": [--quiet] <path> <commit>
                # Find first positional (non-flag) argument = the worktree path.
                wt_path=""
                for arg in "${rest[@]:1}"; do
                    case "$arg" in
                        --*|-*) continue ;;
                        *) wt_path="$arg"; break ;;
                    esac
                done
                mkdir -p "$wt_path"
                exit 0
                ;;
            remove)
                rm -rf "${rest[-1]}" 2>/dev/null || true
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    rebase)
        if [ "$action" = "--abort" ]; then
            exit 0
        fi
        exit "${MOCK_REBASE_EXIT:-0}"
        ;;
    diff)
        printf '%s\n' "${MOCK_CONFLICTED_FILES:-}"
        exit 0
        ;;
    push)
        exit "${MOCK_PUSH_EXIT:-0}"
        ;;
    log)
        echo "${MOCK_GIT_LOG_OUTPUT:-abc1234 mock commit subject}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GITEOF
    chmod +x "$BATS_TMPDIR/bin/git"
    # Re-prepend mock bin after env.sh may have modified PATH during source.
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export GIT_LOG

    # Stubs: always reference vars without brace-expansion defaults to avoid
    # the bash issue where ${VAR:-{}} appends a literal } when VAR is set.
    backend_list_open_prs_raw() { echo "$MOCK_PRS_JSON"; }
    backend_pr_view()           { echo "$MOCK_PR_VIEW_JSON"; }
    backend_add_label()         { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_remove_label()      { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_comment_pr()        { echo "comment_pr $2: $3"  >> "$OPS_LOG"; }

    loop_stage_trigger()        { echo "needs-rework"; }
    loop_notify()               { :; }
    _loop_emit_event()          { echo "emit_event $1" >> "$OPS_LOG"; }
    log()                       { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$OPS_LOG" "$GIT_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# (a) DIRTY PR, clean rebase → push called, no labels mutated
# ---------------------------------------------------------------------------

@test "reconcile_pr_base_moved: DIRTY PR clean rebase calls force-with-lease push" {
    export MOCK_PRS_JSON='[{
        "number": 10,
        "headRefName": "feat/issue-5-add-auth",
        "labels": [],
        "body": "Closes #5",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=0

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "force-with-lease" "$GIT_LOG"
}

@test "reconcile_pr_base_moved: DIRTY PR clean rebase does not mutate labels" {
    export MOCK_PRS_JSON='[{
        "number": 10,
        "headRefName": "feat/issue-5-add-auth",
        "labels": [],
        "body": "Closes #5",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=0

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label|remove_label" "$OPS_LOG"
}

@test "reconcile_pr_base_moved: DIRTY PR clean rebase emits pr_rebased event" {
    export MOCK_PRS_JSON='[{
        "number": 10,
        "headRefName": "feat/issue-5-add-auth",
        "labels": [],
        "body": "Closes #5",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=0

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "emit_event pr_rebased" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (b) DIRTY PR, rebase conflict → needs-rework + comment with file names
# ---------------------------------------------------------------------------

@test "reconcile_pr_base_moved: conflict applies needs-rework to PR" {
    export MOCK_PRS_JSON='[{
        "number": 20,
        "headRefName": "feat/issue-7-cache",
        "labels": [],
        "body": "Closes #7",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=1
    export MOCK_CONFLICTED_FILES=$'lib/cache.sh\nlib/runner.sh'

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "add_label 20 needs-rework" "$OPS_LOG"
}

@test "reconcile_pr_base_moved: conflict posts comment containing both conflicted file names" {
    export MOCK_PRS_JSON='[{
        "number": 20,
        "headRefName": "feat/issue-7-cache",
        "labels": [],
        "body": "Closes #7",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=1
    export MOCK_CONFLICTED_FILES=$'lib/cache.sh\nlib/runner.sh'

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "comment_pr 20" "$OPS_LOG"
    grep -q "lib/cache.sh" "$OPS_LOG"
    grep -q "lib/runner.sh" "$OPS_LOG"
}

@test "reconcile_pr_base_moved: conflict strips trigger labels from parent issue" {
    export MOCK_PRS_JSON='[{
        "number": 20,
        "headRefName": "feat/issue-7-cache",
        "labels": [],
        "body": "Closes #7",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=1
    export MOCK_CONFLICTED_FILES="lib/cache.sh"

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -qE "remove_label 7 (needs-dev|in-dev|dev|in-progress)" "$OPS_LOG"
}

@test "reconcile_pr_base_moved: conflict emits pr_rebase_conflict event" {
    export MOCK_PRS_JSON='[{
        "number": 20,
        "headRefName": "feat/issue-7-cache",
        "labels": [],
        "body": "Closes #7",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=1
    export MOCK_CONFLICTED_FILES="lib/cache.sh"

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "emit_event pr_rebase_conflict" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (c) PR already has needs-rework → no-op
# ---------------------------------------------------------------------------

@test "reconcile_pr_base_moved: PR with needs-rework label is skipped" {
    export MOCK_PRS_JSON='[{
        "number": 30,
        "headRefName": "feat/issue-9-nav",
        "labels": [{"name":"needs-rework"}],
        "body": "Closes #9",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=0

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    # git should never be invoked for a skipped PR.
    [ ! -s "$GIT_LOG" ] || ! grep -q "rebase" "$GIT_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label|remove_label|comment_pr" "$OPS_LOG"
}

@test "reconcile_pr_base_moved: PR with changes-requested label is skipped" {
    export MOCK_PRS_JSON='[{
        "number": 31,
        "headRefName": "feat/issue-11-search",
        "labels": [{"name":"changes-requested"}],
        "body": "Closes #11",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label|remove_label|comment_pr" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (d) AUTO_REBASE_ON_BASE_MOVE=false → no-op
# ---------------------------------------------------------------------------

@test "reconcile_pr_base_moved: AUTO_REBASE_ON_BASE_MOVE=false skips sweep entirely" {
    export AUTO_REBASE_ON_BASE_MOVE=false
    export MOCK_PRS_JSON='[{
        "number": 40,
        "headRefName": "feat/issue-15-login",
        "labels": [],
        "body": "Closes #15",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'
    export MOCK_REBASE_EXIT=0

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$GIT_LOG" ] || ! grep -q "rebase" "$GIT_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label|remove_label|comment_pr" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Extra: CLEAN merge state → no rebase attempted
# ---------------------------------------------------------------------------

@test "reconcile_pr_base_moved: CLEAN mergeStateStatus → no rebase" {
    export MOCK_PRS_JSON='[{
        "number": 50,
        "headRefName": "feat/issue-20-docs",
        "labels": [],
        "body": "Closes #20",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "CLEAN",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": []
    }'

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$GIT_LOG" ] || ! grep -q "rebase" "$GIT_LOG"
}

# ---------------------------------------------------------------------------
# Extra: human review present → no-op
# ---------------------------------------------------------------------------

@test "reconcile_pr_base_moved: PR with human review is skipped" {
    export MOCK_PRS_JSON='[{
        "number": 60,
        "headRefName": "feat/issue-25-api",
        "labels": [],
        "body": "Closes #25",
        "updatedAt": "2026-01-01T00:00:00Z"
    }]'
    export MOCK_PR_VIEW_JSON='{
        "mergeStateStatus": "DIRTY",
        "mergeable": "MERGEABLE",
        "baseRefName": "main",
        "latestReviews": [{"state": "APPROVED"}]
    }'
    export MOCK_REBASE_EXIT=0

    run reconcile_pr_base_moved "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$GIT_LOG" ] || ! grep -q "rebase" "$GIT_LOG"
    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label|remove_label|comment_pr" "$OPS_LOG"
}
