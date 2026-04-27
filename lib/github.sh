#!/usr/bin/env bash
# lib/github.sh — thin wrappers around gh + jq.

set -euo pipefail

# loop_issue_parent_epic <repo> <number>
# Parses the issue body for an epic reference (case-insensitive, first match):
#   "Epic: #NNN" | "Child of #NNN" | "Parent: #NNN" | "Part of #NNN"
# Prints the epic issue number, or 9999999 when none is found.
loop_issue_parent_epic() {
    local repo="$1" number="$2"
    local body match
    body=$(gh issue view "$number" --repo "$repo" --json body --jq '.body' 2>/dev/null) || { echo 9999999; return; }
    [ -z "$body" ] || [ "$body" = "null" ] && { echo 9999999; return; }
    match=$(printf '%s' "$body" \
        | grep -ioE '(epic[[:space:]]*:|child of|parent[[:space:]]*:|part of)[[:space:]]*#([0-9]+)' \
        | head -1 \
        | grep -oE '[0-9]+$') || true
    printf '%s\n' "${match:-9999999}"
}

# loop_gh_issues_with_label <repo> <label>
# Emits: one issue per line, JSON: {"number","title","url","labels":["..."]}
# Sort order (highest priority first):
#   0. Parent epic number ascending (orphans last, sentinel 9999999)
#   1. Explicit priority label: p0-critical < p1-high < p2-medium < p3-low < unlabeled
#   2. Bugs before non-bugs
#   3. Issue number ascending (oldest first — prevents starvation)
loop_gh_issues_with_label() {
    local repo="$1" label="$2"
    local raw_tmp sort_tmp
    raw_tmp=$(mktemp)
    sort_tmp=$(mktemp)

    gh issue list --repo "$repo" --label "$label" --state open \
        --json number,title,url,labels,author \
        --jq '
          map(
            ([.labels[].name]) as $L |
            {
              number, title, url, labels: $L, author: .author.login,
              _p: (
                if   ($L | index("p0-critical")) then 0
                elif ($L | index("p1-high"))     then 1
                elif ($L | index("p2-medium"))   then 2
                elif ($L | index("p3-low"))      then 3
                else 4 end),
              _b: (if ($L | index("bug")) then 0 else 1 end)
            }
          )[]
        ' 2>/dev/null >"$raw_tmp" || true

    if [ ! -s "$raw_tmp" ]; then
        rm -f "$raw_tmp" "$sort_tmp"
        return
    fi

    while IFS= read -r obj; do
        local num _p _b epic clean
        num=$(printf '%s' "$obj" | jq -r '.number')
        _p=$(printf '%s'  "$obj" | jq -r '._p')
        _b=$(printf '%s'  "$obj" | jq -r '._b')
        epic=$(loop_issue_parent_epic "$repo" "$num")
        clean=$(printf '%s' "$obj" | jq -c '{number, title, url, labels, author}')
        printf '%07d %d %d %07d %s\n' "$epic" "$_p" "$_b" "$num" "$clean" >>"$sort_tmp"
    done <"$raw_tmp"

    sort "$sort_tmp" | cut -d' ' -f5-

    rm -f "$raw_tmp" "$sort_tmp"
}

# loop_gh_prs_with_label <repo> <label>
# Emits: one PR per line, JSON: {"number","title","url","labels":["..."],"headRefName"}
# Same priority sort as issues.
loop_gh_prs_with_label() {
    local repo="$1" label="$2"
    gh pr list --repo "$repo" --label "$label" --state open \
        --json number,title,url,labels,headRefName,mergeable \
        --jq '
          map(
            ([.labels[].name]) as $L |
            {
              number, title, url, headRefName, mergeable, labels: $L,
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
          | .[] | {number, title, url, headRefName, mergeable, labels}
        ' 2>/dev/null || true
}

loop_add_label() {
    local repo="$1" number="$2" label="$3"
    gh issue edit "$number" --repo "$repo" --add-label "$label" 2>/dev/null \
        || gh pr edit "$number" --repo "$repo" --add-label "$label" 2>/dev/null \
        || true
}

loop_remove_label() {
    local repo="$1" number="$2" label="$3"
    gh issue edit "$number" --repo "$repo" --remove-label "$label" 2>/dev/null \
        || gh pr edit "$number" --repo "$repo" --remove-label "$label" 2>/dev/null \
        || true
}

# loop_issue_has_any_label <repo> <number> <label1> [label2 ...]
# Returns 0 if the issue carries at least one of the labels, 1 otherwise.
loop_issue_has_any_label() {
    local repo="$1" number="$2"; shift 2
    local names
    names=$(gh issue view "$number" --repo "$repo" --json labels --jq '.labels[].name' 2>/dev/null) || return 1
    for want in "$@"; do
        if echo "$names" | grep -qx "$want"; then
            return 0
        fi
    done
    return 1
}

# loop_pr_has_any_label <repo> <number> <label1> [label2 ...]
loop_pr_has_any_label() {
    local repo="$1" number="$2"; shift 2
    local names
    names=$(gh pr view "$number" --repo "$repo" --json labels --jq '.labels[].name' 2>/dev/null) || return 1
    for want in "$@"; do
        if echo "$names" | grep -qx "$want"; then
            return 0
        fi
    done
    return 1
}

# loop_issue_dependency_refs <repo> <number>
# Print all #NNN references found inside a "## Dependencies" section of the
# issue body, one per line. Empty output = no dependencies declared.
# Recognizes both "## Dependencies" and "### Dependencies" headings.
# Section ends at the next "##" heading or EOF.
loop_issue_dependency_refs() {
    local repo="$1" number="$2"
    local body
    body=$(gh issue view "$number" --repo "$repo" --json body --jq '.body' 2>/dev/null) || return 0
    [ -z "$body" ] && return 0

    printf '%s\n' "$body" | awk '
        BEGIN { in_section = 0 }
        /^##+[[:space:]]+[Dd]ependencies[[:space:]]*$/ { in_section = 1; next }
        in_section && /^##[[:space:]]/ { in_section = 0 }
        in_section { print }
    ' | grep -oE '#[0-9]+' | sed 's/^#//' | sort -u
}

# loop_issue_unmet_deps <repo> <number>
# Print each unmet dependency as "#NNN" on its own line. Empty output = all met.
# A dependency is "met" when the referenced issue/PR is CLOSED (gh api state).
loop_issue_unmet_deps() {
    local repo="$1" number="$2"
    local deps
    deps=$(loop_issue_dependency_refs "$repo" "$number") || return 0
    [ -z "$deps" ] && return 0

    while IFS= read -r dep_num; do
        [ -z "$dep_num" ] && continue
        [ "$dep_num" = "$number" ] && continue   # self-reference guard
        local state
        state=$(gh api "/repos/${repo}/issues/${dep_num}" --jq '.state' 2>/dev/null) || state="open"
        if [ "$state" != "closed" ]; then
            echo "#${dep_num}"
        fi
    done <<< "$deps"
}
