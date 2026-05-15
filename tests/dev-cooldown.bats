#!/usr/bin/env bats
# tests/dev-cooldown.bats — unit tests for lib/dev_cooldown.sh (#397).
#
# All external calls (gh, git) are intercepted by overriding the internal
# helper functions (_loop_cooldown_merged_prs, _loop_cooldown_pr_files,
# _loop_cooldown_local_files) so tests run without network or git access.

setup() {
    LOOP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/dev_cooldown.sh
    source "$LOOP_ROOT/lib/dev_cooldown.sh"
}

# ---------------------------------------------------------------------------
# Helper: build a fake merged-prs list string ("pr_num merged_at" per line).
# ---------------------------------------------------------------------------
_fake_merged_prs() {
    local pr_num="$1" merged_at="${2:-2026-05-14T10:45:00Z}"
    printf '%s %s\n' "$pr_num" "$merged_at"
}

# ---------------------------------------------------------------------------
# No merged PRs in window → clear
# ---------------------------------------------------------------------------

@test "no merged PRs in window → clear" {
    _loop_cooldown_merged_prs() { true; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    run loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 30
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Merged PR with overlapping file → blocked
# ---------------------------------------------------------------------------

@test "merged PR with overlapping file → blocked" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'scripts/dashboard.py\nlib/util.py\n'; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    run loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 30
    [ "$status" -eq 1 ]
}

@test "blocked: DEV_COOLDOWN_BLOCK_PR is set to the conflicting PR number" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'scripts/dashboard.py\n'; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\nlib/other.py\n'; }

    loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 30 || true
    [ "${DEV_COOLDOWN_BLOCK_PR:-}" = "285" ]
}

# ---------------------------------------------------------------------------
# Non-overlapping files → clear
# ---------------------------------------------------------------------------

@test "merged PR touches different files → clear" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'lib/util.py\nlib/config.py\n'; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    run loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 30
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Follow-up annotation bypasses the guard
# ---------------------------------------------------------------------------

@test "follow-up annotation for the conflicting PR → clear" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'scripts/dashboard.py\n'; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    local issue_body
    issue_body=$(printf 'Some task\n\n## Follow-up of #285\n\nDoing more work.')
    run loop_dev_cooldown_check "owner/repo" "$issue_body" "/fake/worktree" "main" 30
    [ "$status" -eq 0 ]
}

@test "follow-up annotation for a different PR does not bypass guard" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'scripts/dashboard.py\n'; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    local issue_body
    issue_body=$(printf 'Some task\n\n## Follow-up of #999\n\nDoing more work.')
    run loop_dev_cooldown_check "owner/repo" "$issue_body" "/fake/worktree" "main" 30
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# cooldown_minutes=0 disables the guard entirely
# ---------------------------------------------------------------------------

@test "cooldown_minutes=0 → guard disabled, always clear" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'scripts/dashboard.py\n'; }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    run loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 0
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Empty local diff → clear (nothing to overlap)
# ---------------------------------------------------------------------------

@test "empty local diff → clear" {
    _loop_cooldown_merged_prs() { _fake_merged_prs 285 "2026-05-14T10:45:00Z"; }
    _loop_cooldown_pr_files()   { printf 'scripts/dashboard.py\n'; }
    _loop_cooldown_local_files() { true; }

    run loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 30
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Multiple merged PRs: only the overlapping one triggers block
# ---------------------------------------------------------------------------

@test "multiple merged PRs: block only when file overlap exists" {
    _loop_cooldown_merged_prs() {
        printf '100 2026-05-14T10:00:00Z\n'
        printf '285 2026-05-14T10:45:00Z\n'
    }
    _loop_cooldown_pr_files() {
        local pr="$2"
        case "$pr" in
            100) printf 'lib/unrelated.py\n' ;;
            285) printf 'scripts/dashboard.py\n' ;;
        esac
    }
    _loop_cooldown_local_files() { printf 'scripts/dashboard.py\n'; }

    # Call directly (not via `run`) so exported DEV_COOLDOWN_BLOCK_PR is visible.
    local rc=0
    loop_dev_cooldown_check "owner/repo" "" "/fake/worktree" "main" 30 || rc=$?
    [ "$rc" -eq 1 ]
    [ "${DEV_COOLDOWN_BLOCK_PR:-}" = "285" ]
}

# ---------------------------------------------------------------------------
# _loop_cooldown_files_overlap unit tests
# ---------------------------------------------------------------------------

@test "_loop_cooldown_files_overlap: match found → returns 0" {
    run _loop_cooldown_files_overlap $'foo.py\nbar.py' $'baz.py\nfoo.py'
    [ "$status" -eq 0 ]
}

@test "_loop_cooldown_files_overlap: no match → returns 1" {
    run _loop_cooldown_files_overlap $'foo.py\nbar.py' $'baz.py\nqux.py'
    [ "$status" -eq 1 ]
}

@test "_loop_cooldown_files_overlap: empty list a → returns 1" {
    run _loop_cooldown_files_overlap '' $'foo.py'
    [ "$status" -eq 1 ]
}
