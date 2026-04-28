#!/usr/bin/env bash
# lib/backends/gitlab.sh — GitLab backend for Loop.
#
# Implements the backend interface (see lib/backends/backend.sh) using glab CLI.
# Maps GitLab Merge Requests to the PR abstraction used throughout Loop.
#
# Configuration:
#   GITLAB_HOST — GitLab instance hostname (default: gitlab.com).
#                 Set this in loop.env for self-hosted installations.
#
# Repo format in projects.yaml:
#   gitlab.com (cloud):   group/project
#   self-hosted:          gitlab.example.com/group/project
#                         (host is parsed from the first path component;
#                          GITLAB_HOST is exported automatically)
#
# Requirements: glab CLI authenticated (glab auth login)

set -euo pipefail

# Guard against double-sourcing.
[ -n "${_LOOP_BACKEND_GITLAB_LOADED:-}" ] && return 0
_LOOP_BACKEND_GITLAB_LOADED=1

# _gl_parse_repo <repo>
# Sets _GL_REPO (path to pass to --repo) and exports GITLAB_HOST when the
# repo string encodes a hostname (three or more slash-separated components).
_gl_parse_repo() {
    local repo="$1"
    local part0 part1 part2 rest
    part0="${repo%%/*}"
    rest="${repo#*/}"
    part1="${rest%%/*}"
    part2="${rest#*/}"

    # Three components → first is the host.
    if [ "$rest" != "$part2" ]; then
        export GITLAB_HOST="$part0"
        _GL_REPO="${part1}/${part2}"
    else
        _GL_REPO="$repo"
        # GITLAB_HOST remains whatever is already in the environment.
    fi
}

# Priority-sort jq fragment for issues.
# Input: JSON array from glab issue list --output json
# Output: JSONL with Loop schema {number, title, url, labels}
_GL_ISSUE_SORT='
  map(
    (.labels // []) as $L |
    {
      number: .iid,
      title,
      url: .web_url,
      labels: $L,
      author: (.author.username // ""),
      _p: (
        if   ($L | index("p0-critical")) then 0
        elif ($L | index("p1-high"))     then 1
        elif ($L | index("p2-medium"))   then 2
        elif ($L | index("p3-low"))      then 3
        else 4 end),
      _b: (if ($L | index("bug")) then 0 else 1 end)
    }
  )
  | sort_by([._p, ._b, .number])
  | .[] | del(._p, ._b)
'

# Priority-sort jq fragment for MRs.
# Output: JSONL with Loop schema {number, title, url, headRefName, labels}
_GL_MR_SORT='
  map(
    (.labels // []) as $L |
    {
      number: .iid,
      title,
      url: .web_url,
      headRefName: .source_branch,
      labels: $L,
      _p: (
        if   ($L | index("p0-critical")) then 0
        elif ($L | index("p1-high"))     then 1
        elif ($L | index("p2-medium"))   then 2
        elif ($L | index("p3-low"))      then 3
        else 4 end),
      _b: (if ($L | index("bug")) then 0 else 1 end)
    }
  )
  | sort_by([._p, ._b, .number])
  | .[] | del(._p, ._b)
'

# ---------------------------------------------------------------------------
# Core interface
# ---------------------------------------------------------------------------

# backend_list_issues_with_label <repo> <label>
backend_list_issues_with_label() {
    local repo="$1" label="$2"
    _gl_parse_repo "$repo"
    glab issue list --repo "$_GL_REPO" --label "$label" \
        --output json 2>/dev/null \
    | jq -c "$_GL_ISSUE_SORT" 2>/dev/null || true
}

# backend_list_prs_with_label <repo> <label>
# MRs are exposed as the PR abstraction throughout Loop.
backend_list_prs_with_label() {
    local repo="$1" label="$2"
    _gl_parse_repo "$repo"
    glab mr list --repo "$_GL_REPO" --label "$label" --state opened \
        --output json 2>/dev/null \
    | jq -c "$_GL_MR_SORT" 2>/dev/null || true
}

# backend_add_label <repo> <number> <label>
# Tries issue first; falls back to MR.
backend_add_label() {
    local repo="$1" number="$2" label="$3"
    _gl_parse_repo "$repo"
    glab issue update "$number" --repo "$_GL_REPO" --add-label "$label" 2>/dev/null \
        || glab mr update "$number" --repo "$_GL_REPO" --add-label "$label" 2>/dev/null \
        || true
}

# backend_remove_label <repo> <number> <label>
backend_remove_label() {
    local repo="$1" number="$2" label="$3"
    _gl_parse_repo "$repo"
    glab issue update "$number" --repo "$_GL_REPO" --remove-label "$label" 2>/dev/null \
        || glab mr update "$number" --repo "$_GL_REPO" --remove-label "$label" 2>/dev/null \
        || true
}

# backend_issue_has_any_label <repo> <number> <label1> [label2 ...]
backend_issue_has_any_label() {
    local repo="$1" number="$2"; shift 2
    _gl_parse_repo "$repo"
    local names
    names=$(glab issue view "$number" --repo "$_GL_REPO" --output json 2>/dev/null \
            | jq -r '(.labels // [])[]' 2>/dev/null) || return 1
    local want
    for want in "$@"; do
        if echo "$names" | grep -qx "$want"; then
            return 0
        fi
    done
    return 1
}

# backend_pr_has_any_label <repo> <number> <label1> [label2 ...]
backend_pr_has_any_label() {
    local repo="$1" number="$2"; shift 2
    _gl_parse_repo "$repo"
    local names
    names=$(glab mr view "$number" --repo "$_GL_REPO" --output json 2>/dev/null \
            | jq -r '(.labels // [])[]' 2>/dev/null) || return 1
    local want
    for want in "$@"; do
        if echo "$names" | grep -qx "$want"; then
            return 0
        fi
    done
    return 1
}

# backend_issue_view <repo> <number> [extra_flags...]
# Returns full JSON output from glab. GitHub-style --json/--jq flags are not
# forwarded; callers should parse the native glab JSON themselves.
backend_issue_view() {
    local repo="$1" number="$2"
    _gl_parse_repo "$repo"
    glab issue view "$number" --repo "$_GL_REPO" --output json 2>/dev/null || true
}

# backend_pr_view <repo> <number> [extra_flags...]
backend_pr_view() {
    local repo="$1" number="$2"
    _gl_parse_repo "$repo"
    glab mr view "$number" --repo "$_GL_REPO" --output json 2>/dev/null || true
}

# backend_open_pr <repo> <title> <body_file> <label>
# Opens a GitLab Merge Request from the current branch.
backend_open_pr() {
    local repo="$1" title="$2" body_file="$3" label="$4"
    _gl_parse_repo "$repo"
    local body
    body=$(cat "$body_file")
    glab mr create --repo "$_GL_REPO" \
        --title "$title" \
        --description "$body" \
        --label "$label" \
        2>/dev/null || true
}

# backend_close_issue <repo> <number>
backend_close_issue() {
    local repo="$1" number="$2"
    _gl_parse_repo "$repo"
    glab issue close "$number" --repo "$_GL_REPO" 2>/dev/null || true
}

# backend_close_pr <repo> <number> [--delete-branch]
# Closes the MR. With --delete-branch, deletes the source branch via the API.
backend_close_pr() {
    local repo="$1" number="$2"; shift 2
    _gl_parse_repo "$repo"
    local delete_branch=false
    local arg
    for arg in "$@"; do
        [ "$arg" = "--delete-branch" ] && delete_branch=true
    done

    glab mr close "$number" --repo "$_GL_REPO" 2>/dev/null || true

    if $delete_branch; then
        local branch
        branch=$(glab mr view "$number" --repo "$_GL_REPO" --output json 2>/dev/null \
                 | jq -r '.source_branch // empty' 2>/dev/null || true)
        if [ -n "$branch" ]; then
            local project_enc
            project_enc=$(python3 -c \
                "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" \
                "$_GL_REPO" 2>/dev/null || true)
            local branch_enc
            branch_enc=$(python3 -c \
                "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" \
                "$branch" 2>/dev/null || true)
            if [ -n "$project_enc" ] && [ -n "$branch_enc" ]; then
                glab api "DELETE /projects/$project_enc/repository/branches/$branch_enc" \
                    2>/dev/null || true
            fi
        fi
    fi
}

# backend_comment_issue <repo> <number> <body>
backend_comment_issue() {
    local repo="$1" number="$2" body="$3"
    _gl_parse_repo "$repo"
    glab issue comment "$number" --repo "$_GL_REPO" --body "$body" 2>/dev/null || true
}

# backend_comment_pr <repo> <number> <body>
backend_comment_pr() {
    local repo="$1" number="$2" body="$3"
    _gl_parse_repo "$repo"
    glab mr comment "$number" --repo "$_GL_REPO" --body "$body" 2>/dev/null || true
}

# backend_merge_pr <repo> <number> <strategy_flag>
# <strategy_flag>: --squash | --merge | --rebase
backend_merge_pr() {
    local repo="$1" number="$2" strategy_flag="$3"
    _gl_parse_repo "$repo"
    local gl_args=("$number" "--repo" "$_GL_REPO" "--remove-source-branch")
    case "$strategy_flag" in
        --squash) gl_args+=("--squash") ;;
        --rebase) gl_args+=("--rebase") ;;
        --merge)  ;;
    esac
    glab mr merge "${gl_args[@]}"
}

# ---------------------------------------------------------------------------
# Extended interface — bulk operations used by scanner/reconciler
# ---------------------------------------------------------------------------

# backend_list_open_prs_raw <repo>
# Returns a JSON array of open MRs normalized to the Loop PR schema.
backend_list_open_prs_raw() {
    local repo="$1"
    _gl_parse_repo "$repo"
    glab mr list --repo "$_GL_REPO" --state opened --limit 100 \
        --output json 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        body: (.description // ""),
        createdAt: .created_at,
        headRefName: .source_branch,
        title,
        labels: (.labels // []),
        updatedAt: .updated_at
      }]' 2>/dev/null || echo "[]"
}

# backend_list_merged_prs_raw <repo>
# Returns a JSON array of recently merged MRs with number and body.
backend_list_merged_prs_raw() {
    local repo="$1"
    _gl_parse_repo "$repo"
    glab mr list --repo "$_GL_REPO" --state merged --limit 100 \
        --output json 2>/dev/null \
    | jq '[.[] | {number: .iid, body: (.description // "")}]' \
    2>/dev/null || echo "[]"
}

# backend_list_open_issues_raw <repo> <label>
# Returns a JSON array of open issues with the given label.
backend_list_open_issues_raw() {
    local repo="$1" label="$2"
    _gl_parse_repo "$repo"
    glab issue list --repo "$_GL_REPO" --state opened --label "$label" \
        --limit 100 --output json 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: (.labels // []),
        body: (.description // ""),
        updatedAt: .updated_at
      }]' 2>/dev/null || echo "[]"
}
