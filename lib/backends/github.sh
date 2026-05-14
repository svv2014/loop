#!/usr/bin/env bash
# lib/backends/github.sh — GitHub backend implementation for Loop.
#
# Wraps lib/github.sh helpers (which must already be sourced) and implements
# the full backend interface defined in lib/backends/backend.sh.
# Do NOT modify lib/github.sh — this file is the only adapter layer.

set -euo pipefail

# Ensure lib/github.sh helpers are available.
_GITHUB_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../github.sh
source "${_GITHUB_BACKEND_DIR}/../github.sh"

# ---------------------------------------------------------------------------
# Core interface (14 functions)
# ---------------------------------------------------------------------------

backend_list_issues_with_label() {
    local repo="$1" label="$2"
    loop_gh_issues_with_label "$repo" "$label"
}

# backend_issue_unmet_deps <repo> <number>
backend_issue_unmet_deps() {
    local repo="$1" number="$2"
    loop_issue_unmet_deps "$repo" "$number"
}

backend_list_prs_with_label() {
    local repo="$1" label="$2"
    loop_gh_prs_with_label "$repo" "$label"
}

backend_add_label() {
    local repo="$1" number="$2" label="$3"
    loop_add_label "$repo" "$number" "$label"
}

backend_remove_label() {
    # Accepts one or more labels and removes each. Previously the function
    # silently dropped args beyond the 3rd, which caused several callers
    # in review-handler / dev-handler / qa-handler to fail silently when
    # passing a list of labels to strip.
    local repo="$1" number="$2"
    shift 2
    local label
    for label in "$@"; do
        [ -z "$label" ] && continue
        loop_remove_label "$repo" "$number" "$label"
    done
}

# backend_issue_has_any_label <repo> <number> <label1> [label2 ...]
backend_issue_has_any_label() {
    local repo="$1" number="$2"
    shift 2
    loop_issue_has_any_label "$repo" "$number" "$@"
}

# backend_pr_has_any_label <repo> <number> <label1> [label2 ...]
backend_pr_has_any_label() {
    local repo="$1" number="$2"
    shift 2
    loop_pr_has_any_label "$repo" "$number" "$@"
}

# backend_issue_view <repo> <number> [extra_flags...]
# Extra flags (e.g. --json fields --jq expr) are forwarded to gh issue view.
backend_issue_view() {
    local repo="$1" number="$2"
    shift 2
    gh issue view "$number" --repo "$repo" "$@"
}

# backend_pr_view <repo> <number> [extra_flags...]
backend_pr_view() {
    local repo="$1" number="$2"
    shift 2
    gh pr view "$number" --repo "$repo" "$@"
}

# backend_open_pr <repo> <title> <body_file> <label>
backend_open_pr() {
    local repo="$1" title="$2" body_file="$3" label="$4"
    gh pr create --repo "$repo" --title "$title" --body-file "$body_file" --label "$label" --draft
}

# backend_close_issue <repo> <number>
backend_close_issue() {
    local repo="$1" number="$2"
    gh issue close "$number" --repo "$repo" 2>/dev/null || true
}

# backend_close_pr <repo> <number> [--delete-branch]
backend_close_pr() {
    local repo="$1" number="$2"
    shift 2
    local delete_branch=false
    for arg in "$@"; do
        [ "$arg" = "--delete-branch" ] && delete_branch=true
    done
    if $delete_branch; then
        gh pr close "$number" --repo "$repo" --delete-branch 2>/dev/null || true
    else
        gh pr close "$number" --repo "$repo" 2>/dev/null || true
    fi
}

# backend_comment_issue <repo> <number> <body>
backend_comment_issue() {
    local repo="$1" number="$2" body="$3"
    gh issue comment "$number" --repo "$repo" --body "$body" 2>/dev/null || true
}

# backend_comment_pr <repo> <number> <body>
backend_comment_pr() {
    local repo="$1" number="$2" body="$3"
    gh pr comment "$number" --repo "$repo" --body "$body" 2>/dev/null || true
}

# backend_pr_ready <repo> <number>
# Promotes a draft PR to ready-for-review. No-op if already ready.
backend_pr_ready() {
    local repo="$1" number="$2"
    gh pr ready "$number" --repo "$repo" 2>/dev/null || true
}

# backend_merge_pr <repo> <number> <strategy_flag>
# <strategy_flag> is one of: --squash, --merge, --rebase
backend_merge_pr() {
    local repo="$1" number="$2" strategy_flag="$3"
    gh pr merge "$number" "$strategy_flag" --repo "$repo" --delete-branch
}

# backend_find_pr_for_issue <repo> <issue_num>
# Prints the open PR number whose body closes the given issue, or empty string.
# Always exits 0.
backend_find_pr_for_issue() {
    local repo="$1" issue_num="$2"
    local result
    result=$(gh pr list --repo "$repo" --state open \
        --json number \
        --search "Closes #${issue_num} in:body" \
        2>/dev/null \
        | python3 -c "
import json, sys
prs = json.load(sys.stdin)
print(prs[0]['number'] if prs else '')
" 2>/dev/null || true)
    printf '%s' "${result:-}"
}

# ---------------------------------------------------------------------------
# Extended interface — bulk operations used by reconciler
# ---------------------------------------------------------------------------

# backend_list_open_prs_raw <repo>
# Returns a raw JSON array of open PRs with fields:
# number, body, createdAt, headRefName, title, labels, updatedAt, author
# `author` is flattened to the bare login string (gh returns it as a nested
# object by default; we project the login so downstream callers can use
# `pr["author"]` as a string).
backend_list_open_prs_raw() {
    local repo="$1"
    gh pr list --repo "$repo" --state open --limit 100 \
        --json number,body,createdAt,headRefName,title,labels,updatedAt,author \
        --jq 'map({number, body, createdAt, headRefName, title, labels, updatedAt, author: (.author.login // "")})' \
        2>/dev/null || echo "[]"
}

# backend_list_merged_prs_raw <repo>
# Returns a raw JSON array of recently merged PRs with fields: number, body
backend_list_merged_prs_raw() {
    local repo="$1"
    gh pr list --repo "$repo" --state merged --limit 100 \
        --json number,body \
        2>/dev/null || echo "[]"
}

# backend_list_open_issues_raw <repo> <label>
# Returns a raw JSON array of open issues with the given label, with fields:
# number, title, labels, body, updatedAt
backend_list_open_issues_raw() {
    local repo="$1" label="$2"
    gh issue list --repo "$repo" --state open --label "$label" --limit 100 \
        --json number,title,labels,body,updatedAt \
        2>/dev/null || echo "[]"
}
