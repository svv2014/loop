#!/usr/bin/env bats
# Regression test for the gh-issue-list / pr-shared-number-space bug.
#
# `gh issue list` returns BOTH issues and PRs because GitHub's API treats
# PRs as a kind of issue with shared number space. Without filtering, a PR
# carrying an issue-stage trigger label (e.g. `needs-dev`) gets emitted by
# the scanner as a `loop.dev_issue` event with a PR-shaped payload
# (pr_number, no issue_number) — breaks downstream interpolation and
# dispatches dev-handler against a PR.
#
# loop_gh_issues_with_label must filter on `.url contains "/issues/"`.
# This test exercises just the jq filter against synthetic input — kept
# narrow because mocking the full gh+pipeline is brittle.

setup() {
    INPUT=$(cat <<'JSON'
[
  {"number": 100, "title": "real issue", "url": "https://github.com/svv2014/repo/issues/100", "labels": [{"name": "needs-dev"}], "author": {"login": "svv2014"}},
  {"number": 200, "title": "secret PR",  "url": "https://github.com/svv2014/repo/pull/200",   "labels": [{"name": "needs-dev"}], "author": {"login": "svv2014"}}
]
JSON
)
}

@test "filter expression keeps issues, drops PRs" {
    output=$(printf '%s' "$INPUT" | jq '
      map(select(.url | contains("/issues/"))) | map(.number)
    ')
    [[ "$output" == *"100"* ]]
    [[ "$output" != *"200"* ]]
}

@test "filter expression survives an empty input" {
    output=$(printf '[]' | jq '
      map(select(.url | contains("/issues/")))
    ')
    [ "$output" = "[]" ]
}

@test "filter expression keeps mixed-shape issues with all required fields" {
    output=$(printf '%s' "$INPUT" | jq '
      map(select(.url | contains("/issues/")))
    ')
    [[ "$output" == *"\"number\": 100"* ]]
    [[ "$output" == *"\"url\": \"https://github.com/svv2014/repo/issues/100\""* ]]
}

@test "lib/github.sh contains the contains-check filter" {
    LOOP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    grep -q 'select(.url | contains("/issues/"))' "$LOOP_ROOT/lib/github.sh"
}
