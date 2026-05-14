#!/usr/bin/env bats
# tests/reconciler-branch-prefix.bats — covers _loop_branch_pattern (#379).
#
# Verifies: default pattern matches feat/fix/chore/docs/issue-N-*, rejects
# unrelated branches; legacy LOOP_BRANCH_PREFIX shortcut still works.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOG_FILE="$LOOP_LOG_DIR/loop-reconciler.log"

    export LOOP_RECONCILER_LIB_ONLY=1
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"
}

# Helper: returns 0 iff branch matches the effective pattern with group(1)=issue_num.
_match() {
    local branch="$1" pattern
    pattern=$(_loop_branch_pattern)
    BRANCH="$branch" PATTERN="$pattern" python3 -c '
import os, re, sys
m = re.match(os.environ["PATTERN"], os.environ["BRANCH"])
if not m:
    sys.exit(1)
print(m.group(1))
' 2>/dev/null
}

@test "default pattern matches feat/issue-42-foo" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "feat/issue-42-foo"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "default pattern matches fix/issue-100-bug-name" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "fix/issue-100-bug-name"
    [ "$status" -eq 0 ]
    [ "$output" = "100" ]
}

@test "default pattern matches chore/issue-7-cleanup" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "chore/issue-7-cleanup"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

@test "default pattern matches docs/issue-321-readme" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "docs/issue-321-readme"
    [ "$status" -eq 0 ]
    [ "$output" = "321" ]
}

@test "default pattern rejects main" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "main"
    [ "$status" -ne 0 ]
}

@test "default pattern rejects random feature branch" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "feature/unrelated-thing"
    [ "$status" -ne 0 ]
}

@test "default pattern rejects branch without issue number" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "feat/no-issue-here"
    [ "$status" -ne 0 ]
}

@test "default pattern rejects unrelated prefix (refactor/issue-1-x)" {
    unset LOOP_BRANCH_PREFIX LOOP_BRANCH_PATTERN
    run _match "refactor/issue-1-x"
    [ "$status" -ne 0 ]
}

@test "legacy LOOP_BRANCH_PREFIX overrides PATTERN with single-prefix shortcut" {
    unset LOOP_BRANCH_PATTERN
    export LOOP_BRANCH_PREFIX="feat/issue-"
    run _match "feat/issue-9-thing"
    [ "$status" -eq 0 ]
    [ "$output" = "9" ]
    # And rejects fix/issue-* — legacy single-prefix mode is strict.
    run _match "fix/issue-9-thing"
    [ "$status" -ne 0 ]
    unset LOOP_BRANCH_PREFIX
}

@test "custom LOOP_BRANCH_PATTERN is honoured" {
    unset LOOP_BRANCH_PREFIX
    export LOOP_BRANCH_PATTERN='^bot/(\d+)-'
    run _match "bot/55-something"
    [ "$status" -eq 0 ]
    [ "$output" = "55" ]
    run _match "feat/issue-1-x"
    [ "$status" -ne 0 ]
    unset LOOP_BRANCH_PATTERN
}
