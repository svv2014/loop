#!/usr/bin/env bats
# tests/github-bulk-body.bats
# Asserts that loop_gh_issues_with_label collapses N+1 API calls into one:
# body is fetched in the bulk gh issue list call; no per-issue gh issue view.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # shellcheck source=../lib/github.sh
    source "$REPO_ROOT/lib/github.sh"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _loop_parse_parent_epic_body
# ---------------------------------------------------------------------------

@test "_loop_parse_parent_epic_body: returns 9999999 for empty body" {
    run _loop_parse_parent_epic_body ""
    [ "$status" -eq 0 ]
    [ "$output" = "9999999" ]
}

@test "_loop_parse_parent_epic_body: returns 9999999 for null body" {
    run _loop_parse_parent_epic_body "null"
    [ "$status" -eq 0 ]
    [ "$output" = "9999999" ]
}

@test "_loop_parse_parent_epic_body: extracts epic from 'Epic: #42'" {
    run _loop_parse_parent_epic_body "Epic: #42"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "_loop_parse_parent_epic_body: extracts epic from 'Child of #100'" {
    run _loop_parse_parent_epic_body "Child of #100"
    [ "$status" -eq 0 ]
    [ "$output" = "100" ]
}

@test "_loop_parse_parent_epic_body: extracts epic from 'Parent: #7'" {
    run _loop_parse_parent_epic_body "Parent: #7"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

@test "_loop_parse_parent_epic_body: extracts epic from 'Part of #55'" {
    run _loop_parse_parent_epic_body "Part of #55"
    [ "$status" -eq 0 ]
    [ "$output" = "55" ]
}

@test "_loop_parse_parent_epic_body: is case-insensitive" {
    run _loop_parse_parent_epic_body "EPIC: #99"
    [ "$status" -eq 0 ]
    [ "$output" = "99" ]
}

@test "_loop_parse_parent_epic_body: returns 9999999 when no pattern matches" {
    run _loop_parse_parent_epic_body "Just a regular issue body with no epic."
    [ "$status" -eq 0 ]
    [ "$output" = "9999999" ]
}

# ---------------------------------------------------------------------------
# loop_gh_issues_with_label — single gh call assertion
# ---------------------------------------------------------------------------

@test "loop_gh_issues_with_label makes exactly one gh call for multiple issues" {
    # Simulate what gh issue list --json ... --jq '...' emits after filtering:
    # two issues shaped with _body, _p, _b fields.
    export GH_MOCK_OUTPUT='{"number":1,"title":"Issue One","url":"https://github.com/owner/repo/issues/1","labels":["needs-dev"],"author":"user1","_body":"Epic: #42","_p":4,"_b":1}
{"number":2,"title":"Issue Two","url":"https://github.com/owner/repo/issues/2","labels":["needs-dev","p1-high"],"author":"user2","_body":"","_p":1,"_b":1}'

    local call_log
    call_log=$(mktemp)
    export GH_MOCK_LOG="$call_log"

    run loop_gh_issues_with_label "owner/repo" "needs-dev"
    [ "$status" -eq 0 ]

    # Each gh invocation starts a new "gh <args>" entry; count only those lines.
    local call_count
    call_count=$(grep -c '^gh ' "$call_log" || true)
    [ "$call_count" -eq 1 ]

    rm -f "$call_log"
}

@test "loop_gh_issues_with_label emits clean JSON without _body field" {
    export GH_MOCK_OUTPUT='{"number":3,"title":"Clean Issue","url":"https://github.com/owner/repo/issues/3","labels":["needs-dev"],"author":"user3","_body":"Epic: #10","_p":4,"_b":1}'

    run loop_gh_issues_with_label "owner/repo" "needs-dev"
    [ "$status" -eq 0 ]
    # Output must be valid JSON and not expose _body
    [[ "$output" != *"_body"* ]]
    [[ "$output" == *'"number":3'* ]]
}

@test "loop_gh_issues_with_label sorts by epic ascending then priority" {
    # Issue 10: no epic (9999999), p1-high
    # Issue 5: epic #2, no priority label
    # Expected order: issue 5 (epic 2) then issue 10 (epic 9999999)
    export GH_MOCK_OUTPUT='{"number":10,"title":"No Epic","url":"https://github.com/owner/repo/issues/10","labels":["needs-dev","p1-high"],"author":"u1","_body":"","_p":1,"_b":1}
{"number":5,"title":"Has Epic","url":"https://github.com/owner/repo/issues/5","labels":["needs-dev"],"author":"u2","_body":"Epic: #2","_p":4,"_b":1}'

    run loop_gh_issues_with_label "owner/repo" "needs-dev"
    [ "$status" -eq 0 ]

    # Issue 5 (epic #2) should appear before issue 10 (no epic)
    issue5_pos=$(echo "$output" | grep -n '"number":5' | cut -d: -f1)
    issue10_pos=$(echo "$output" | grep -n '"number":10' | cut -d: -f1)
    [ "$issue5_pos" -lt "$issue10_pos" ]
}
