#!/usr/bin/env bash
# lib/qa-baseline.sh — diff-aware QA baseline helpers.
#
# Functions exposed:
#   qa_baseline_resolve_sha  <repo> <default_branch>
#   qa_baseline_cache_path   <slug> <sha>
#   qa_baseline_run_or_load  <slug> <sha> <root> <default_branch> <validation_cmd>
#   qa_baseline_diff         <baseline_tap_file> <pr_tap_file>
#   qa_baseline_parse_failing <tap_file>
#
# Escape hatch: callers must check LOOP_QA_DIFF_AWARE != "0" before sourcing any
# of the above; this file does not enforce it so unit tests can call freely.

LOOP_CACHE_DIR="${LOOP_CACHE_DIR:-${HOME}/.loop/cache}"

# qa_baseline_resolve_sha <repo> <default_branch>
# Prints the current commit SHA of <default_branch> on the remote.
# Uses gh API; returns non-zero on failure.
qa_baseline_resolve_sha() {
    local repo="$1"
    local default_branch="${2:-main}"
    gh api "repos/${repo}/commits/${default_branch}" --jq '.sha' 2>/dev/null
}

# qa_baseline_cache_path <slug> <sha>
# Prints the absolute path of the TAP cache file for this slug+sha combination.
qa_baseline_cache_path() {
    local slug="$1"
    local sha="$2"
    echo "${LOOP_CACHE_DIR}/qa-baseline-${slug}-${sha}.tap"
}

# qa_baseline_run_or_load <slug> <sha> <root> <default_branch> <validation_cmd>
# If a cache file for slug+sha already exists, prints its path and returns 0.
# Otherwise: creates a detached git worktree at <sha> inside <root>'s repo,
# runs <validation_cmd> there, writes TAP output to the cache file, removes
# the worktree, and prints the cache path.
# Returns non-zero (and prints nothing) when the worktree cannot be created.
qa_baseline_run_or_load() {
    local slug="$1"
    local sha="$2"
    local root="$3"
    local default_branch="${4:-main}"
    local validation_cmd="$5"

    mkdir -p "$LOOP_CACHE_DIR"
    local cache_file
    cache_file=$(qa_baseline_cache_path "$slug" "$sha")

    if [ -f "$cache_file" ]; then
        echo "$cache_file"
        return 0
    fi

    local tmp_worktree
    tmp_worktree=$(mktemp -d "/tmp/loop-qa-baseline-XXXXXX")

    # Ensure cleanup even on unexpected exits.
    local _wt_cleanup_root="$root"
    local _wt_cleanup_dir="$tmp_worktree"
    trap 'git -C "$_wt_cleanup_root" worktree remove --force "$_wt_cleanup_dir" 2>/dev/null || rm -rf "$_wt_cleanup_dir"' EXIT

    if ! git -C "$root" worktree add --detach "$tmp_worktree" "$sha" 2>/dev/null; then
        rm -rf "$tmp_worktree" 2>/dev/null || true
        trap - EXIT
        return 1
    fi

    # Capture TAP output; a non-zero exit from the test runner is normal when
    # tests fail — we want the output regardless.
    local tap_output
    tap_output=$(cd "$tmp_worktree" && eval "$validation_cmd" 2>&1) || true

    printf '%s\n' "$tap_output" > "$cache_file"

    git -C "$root" worktree remove --force "$tmp_worktree" 2>/dev/null || rm -rf "$tmp_worktree"
    trap - EXIT

    echo "$cache_file"
}

# qa_baseline_parse_failing <tap_file>
# Reads a TAP file and prints each failing test name (one per line).
# Strips trailing TODO/SKIP annotations from the name.
# Prints nothing and returns 0 for an empty or non-TAP file (treated as no failures).
qa_baseline_parse_failing() {
    local tap_file="$1"
    [ -f "$tap_file" ] || return 0

    python3 - "$tap_file" <<'PY'
import sys, re

with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip()
        # Strip TODO/SKIP annotations before matching
        line = re.sub(r'\s*#\s*(TODO|SKIP)\b.*$', '', line, flags=re.IGNORECASE)
        m = re.match(r'^not ok\s+\d+\s*-?\s*(.*)', line)
        if m:
            name = m.group(1).strip()
            if name:
                print(name)
PY
}

# qa_baseline_diff <baseline_tap_file> <pr_tap_file>
# Pure function (no side effects beyond reading the two files).
# Prints one classified line per test to stdout:
#   NEW_FAILURE:<name>    — fails in PR but not in baseline
#   PRE_EXISTING:<name>   — fails in both
#   FIXED:<name>          — fails in baseline but passes in PR
# Exit codes:
#   0  no new failures found
#   1  one or more new failures found
#   2  one or both files are not valid TAP (caller should fall back)
qa_baseline_diff() {
    local baseline_tap="$1"
    local pr_tap="$2"

    python3 - "$baseline_tap" "$pr_tap" <<'PY'
import sys, re

def parse_tap(path):
    """Return (failing_set, is_valid_tap) from a TAP file."""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return set(), False

    failing = set()
    found_tap = False
    for line in lines:
        line = line.rstrip()
        line = re.sub(r'\s*#\s*(TODO|SKIP)\b.*$', '', line, flags=re.IGNORECASE)
        m = re.match(r'^(not ok|ok)\s+\d+\s*-?\s*(.*)', line)
        if m:
            found_tap = True
            status, name = m.group(1), m.group(2).strip()
            if status == 'not ok' and name:
                failing.add(name)
    return failing, found_tap

b_failing, b_valid = parse_tap(sys.argv[1])
p_failing, p_valid = parse_tap(sys.argv[2])

if not b_valid or not p_valid:
    sys.exit(2)

new_failures  = p_failing - b_failing
pre_existing  = p_failing & b_failing
fixed         = b_failing  - p_failing

for name in sorted(new_failures):
    print(f'NEW_FAILURE:{name}')
for name in sorted(pre_existing):
    print(f'PRE_EXISTING:{name}')
for name in sorted(fixed):
    print(f'FIXED:{name}')

sys.exit(1 if new_failures else 0)
PY
}
