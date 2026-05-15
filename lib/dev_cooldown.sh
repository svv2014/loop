#!/usr/bin/env bash
# lib/dev_cooldown.sh — cooldown guard: block PRs that overlap recently-merged files.
#
# Public surface:
#   loop_dev_cooldown_check <repo> <issue_body> <worktree_root> <default_branch> <cooldown_minutes>
#   Returns 0 if the new PR is clear to open, 1 if it must be blocked.
#   On block, exports DEV_COOLDOWN_BLOCK_PR (conflicting PR number) and
#   DEV_COOLDOWN_BLOCK_MINS (approximate minutes since that PR merged).
#
# Per-project configuration: dev.cooldown_minutes in projects.yaml (default 30).
# Set to 0 to disable the guard entirely for a project.
#
# Override bypass: if the issue body contains "## Follow-up of #<pr_number>" for
# the conflicting PR, the guard is skipped for that PR.

set -euo pipefail

# _loop_cooldown_cutoff_iso <minutes>
# Prints an ISO 8601 UTC timestamp for <minutes> ago.
_loop_cooldown_cutoff_iso() {
    python3 -c "
import datetime, sys
mins = int(sys.argv[1])
t = datetime.datetime.utcnow() - datetime.timedelta(minutes=mins)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

# _loop_cooldown_merged_prs <repo> <cutoff_iso>
# Prints "pr_number merged_at_iso" pairs, one per line.
# Mockable in tests by overriding this function.
_loop_cooldown_merged_prs() {
    local repo="$1" cutoff="$2"
    gh pr list --repo "$repo" --state merged \
        --search "merged:>=${cutoff}" \
        --json number,mergedAt --limit 20 2>/dev/null \
    | python3 -c "
import json, sys
prs = json.load(sys.stdin) or []
for p in prs:
    print(str(p.get('number', '')) + ' ' + str(p.get('mergedAt', '')))
" 2>/dev/null || true
}

# _loop_cooldown_pr_files <repo> <pr_number>
# Prints one changed file path per line for the given PR.
# Mockable in tests by overriding this function.
_loop_cooldown_pr_files() {
    local repo="$1" pr_num="$2"
    gh pr view "$pr_num" --repo "$repo" \
        --json files --jq '.files[].path' 2>/dev/null || true
}

# _loop_cooldown_local_files <worktree_root> <default_branch>
# Prints one file path per line for all changes in the worktree vs origin/<branch>.
# Mockable in tests by overriding this function.
_loop_cooldown_local_files() {
    local worktree="$1" branch="$2"
    git -C "$worktree" diff --name-only "origin/${branch}" 2>/dev/null || true
}

# _loop_cooldown_minutes_since <merged_at_iso>
# Prints the number of whole minutes elapsed since the given ISO timestamp.
_loop_cooldown_minutes_since() {
    python3 -c "
import datetime, sys
merged = sys.argv[1]
if not merged:
    print('?')
    sys.exit(0)
try:
    t = datetime.datetime.fromisoformat(merged.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - t).total_seconds() / 60))
except Exception:
    print('?')
" "$1" 2>/dev/null || echo "?"
}

# _loop_cooldown_files_overlap <newline_list_a> <newline_list_b>
# Returns 0 if at least one file appears in both lists, 1 if not.
_loop_cooldown_files_overlap() {
    local files_a="$1" files_b="$2"
    local fa fb
    while IFS= read -r fa; do
        [ -z "$fa" ] && continue
        while IFS= read -r fb; do
            [ -z "$fb" ] && continue
            [ "$fa" = "$fb" ] && return 0
        done <<< "$files_b"
    done <<< "$files_a"
    return 1
}

# loop_dev_cooldown_check <repo> <issue_body> <worktree_root> <default_branch> <cooldown_minutes>
#
# Pre-PR guard: compares the worktree's committed diff against the file sets of
# recently-merged PRs. If any file appears in both sets and the issue body does
# not declare an explicit follow-up annotation, the guard blocks.
#
# Returns 0 — clear, safe to open the PR.
# Returns 1 — blocked; DEV_COOLDOWN_BLOCK_PR and DEV_COOLDOWN_BLOCK_MINS are exported.
loop_dev_cooldown_check() {
    local repo="$1"
    local issue_body="$2"
    local worktree_root="$3"
    local default_branch="$4"
    local cooldown_minutes="${5:-30}"

    # Cooldown disabled for this project.
    [ "$cooldown_minutes" -eq 0 ] 2>/dev/null && return 0

    local cutoff
    cutoff=$(_loop_cooldown_cutoff_iso "$cooldown_minutes")

    local merged_list
    merged_list=$(_loop_cooldown_merged_prs "$repo" "$cutoff") || true
    [ -z "$merged_list" ] && return 0

    local local_files
    local_files=$(_loop_cooldown_local_files "$worktree_root" "$default_branch") || true
    [ -z "$local_files" ] && return 0

    local pr_num merged_at
    while IFS=' ' read -r pr_num merged_at; do
        [ -z "$pr_num" ] && continue

        # Allow explicit follow-up annotation to bypass the guard.
        if printf '%s' "$issue_body" | grep -qE "^## Follow-up of #${pr_num}([^0-9]|$)"; then
            continue
        fi

        local merged_files
        merged_files=$(_loop_cooldown_pr_files "$repo" "$pr_num") || true
        [ -z "$merged_files" ] && continue

        if _loop_cooldown_files_overlap "$local_files" "$merged_files"; then
            export DEV_COOLDOWN_BLOCK_PR="$pr_num"
            export DEV_COOLDOWN_BLOCK_MINS
            DEV_COOLDOWN_BLOCK_MINS=$(_loop_cooldown_minutes_since "$merged_at")
            return 1
        fi
    done <<< "$merged_list"

    return 0
}
