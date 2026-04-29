#!/usr/bin/env bats
# tests/qa-comment.bats — unit tests for qa-handler structured comment helpers.
#
# Tests: AC detection, AC parsing, comment shape (pass/fail/fallback).
# Functions are sourced directly from scripts/qa-handler.sh so tests exercise
# the real implementation, not copy-paste duplicates.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    # Stub the sourced libraries so qa-handler.sh can be loaded without a live env.
    # We only need the helper functions (_qa_*), not the main execution body.
    export LOOP_LOG_DIR="${BATS_TMPDIR:-/tmp}"
    export LOOP_SLUG="test"
    export LOOP_PR_NUMBER="1"

    # Source only the helper functions by extracting and evaling the top of the file.
    # We stop before the main body (LOG_FILE= line) to avoid side-effects.
    _helper_src=$(awk '/^LOG_FILE=/{exit} {print}' "$REPO_ROOT/scripts/qa-handler.sh" \
        | grep -v '^source ' \
        | grep -v '^set -')
    eval "$_helper_src"
}

# ---------------------------------------------------------------------------
# Linked issue extraction — Closes / Fixes / Resolves
# ---------------------------------------------------------------------------

@test "linked issue: extracts issue number from Closes #N" {
    result=$(_qa_linked_issue "Implements the feature.

Closes #42")
    [ "$result" = "42" ]
}

@test "linked issue: extracts issue number from Fixes #N" {
    result=$(_qa_linked_issue "Fixes #17")
    [ "$result" = "17" ]
}

@test "linked issue: extracts issue number from Resolves #N" {
    result=$(_qa_linked_issue "Resolves #99")
    [ "$result" = "99" ]
}

@test "linked issue: case-insensitive match on closes" {
    result=$(_qa_linked_issue "closes #7")
    [ "$result" = "7" ]
}

@test "linked issue: case-insensitive match on FIXES" {
    result=$(_qa_linked_issue "FIXES #3")
    [ "$result" = "3" ]
}

@test "linked issue: returns empty when no known keyword" {
    result=$(_qa_linked_issue "This PR does stuff.")
    [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# AC detection
# ---------------------------------------------------------------------------

@test "AC detection: finds ## Acceptance Criteria section" {
    local body
    body="$(printf '## Summary\nText\n\n## Acceptance Criteria\n- [ ] Criterion one\n- [ ] Criterion two')"
    result=$(_qa_has_ac "$body")
    [ "$result" = "yes" ]
}

@test "AC detection: returns no when section absent" {
    local body
    body="$(printf '## Summary\n- Some summary item')"
    result=$(_qa_has_ac "$body")
    [ "$result" = "no" ]
}

@test "AC detection: returns no for empty body" {
    result=$(_qa_has_ac "")
    [ "$result" = "no" ]
}

# ---------------------------------------------------------------------------
# AC parsing
# ---------------------------------------------------------------------------

@test "AC parsing: extracts two checkboxes" {
    local body
    body="$(printf '## Summary\nText\n\n## Acceptance Criteria\n- [ ] First criterion\n- [ ] Second criterion\n\n## Notes\nExtra')"
    count=$(_qa_parse_acs "$body" | wc -l | tr -d ' ')
    [ "$count" = "2" ]
}

@test "AC parsing: ignores checkboxes outside the section" {
    local body
    body="$(printf '## Notes\n- [ ] Not a criterion\n\n## Acceptance Criteria\n- [ ] Real criterion')"
    output=$(_qa_parse_acs "$body")
    echo "$output" | grep -q "Real criterion"
    ! echo "$output" | grep -q "Not a criterion"
}

@test "AC parsing: returns empty when no Acceptance Criteria section" {
    local body
    body="$(printf '## Summary\n- Some summary')"
    output=$(_qa_parse_acs "$body")
    [ -z "$output" ]
}

@test "AC parsing: handles checked [x] checkboxes" {
    local body
    body="$(printf '## Acceptance Criteria\n- [x] Already done\n- [ ] Not done')"
    count=$(_qa_parse_acs "$body" | wc -l | tr -d ' ')
    [ "$count" = "2" ]
}

# ---------------------------------------------------------------------------
# Comment shape — qa-pass with ACs
# ---------------------------------------------------------------------------

@test "comment qa-pass: contains QA verification heading with issue number" {
    local acs
    acs="$(printf '1. Handler posts structured comment\n2. Comment includes Verdict line')"
    comment=$(_qa_build_comment "42" "qa-pass" "bash -n lib/*.sh" "$acs" "yes")
    echo "$comment" | grep -q "### QA verification — issue #42"
}

@test "comment qa-pass: Phase 1 does NOT use VERIFIED/NOT_FOUND markers (honest — those are agent-only)" {
    local acs
    acs="$(printf '1. Handler posts structured comment\n2. Comment includes Verdict line')"
    comment=$(_qa_build_comment "42" "qa-pass" "bash -n lib/*.sh" "$acs" "yes")
    ! echo "$comment" | grep -q "VERIFIED"
    ! echo "$comment" | grep -q "NOT_FOUND"
}

@test "comment qa-pass: Phase 4 shows [✓ pass] marker" {
    local acs
    acs="$(printf '1. First criterion')"
    comment=$(_qa_build_comment "10" "qa-pass" "make test" "$acs" "yes")
    echo "$comment" | grep -q "Phase 4: validation_cmd"
    echo "$comment" | grep -q "\[✓ pass\]"
}

@test "comment qa-pass: Verdict line is qa-pass" {
    local acs
    acs="$(printf '1. First criterion')"
    comment=$(_qa_build_comment "10" "qa-pass" "make test" "$acs" "yes")
    echo "$comment" | grep -qF "**Verdict:** qa-pass"
}

# ---------------------------------------------------------------------------
# Comment shape — qa-fail with ACs
# ---------------------------------------------------------------------------

@test "comment qa-fail: Phase 4 shows [✗ fail] marker" {
    local acs
    acs="$(printf '1. Handler posts structured comment\n2. Tests cover fallback shape')"
    comment=$(_qa_build_comment "55" "qa-fail" "bash -n lib/*.sh" "$acs" "yes")
    echo "$comment" | grep -q "\[✗ fail\]"
}

@test "comment qa-fail: Phase 1 does NOT use NOT_FOUND markers" {
    local acs
    acs="$(printf '1. Handler posts structured comment')"
    comment=$(_qa_build_comment "55" "qa-fail" "make test" "$acs" "yes")
    ! echo "$comment" | grep -q "NOT_FOUND"
}

@test "comment qa-fail: Verdict line is qa-fail" {
    local acs
    acs="$(printf '1. First criterion')"
    comment=$(_qa_build_comment "55" "qa-fail" "make test" "$acs" "yes")
    echo "$comment" | grep -qF "**Verdict:** qa-fail"
}

# ---------------------------------------------------------------------------
# Comment shape — fallback (no ACs)
# ---------------------------------------------------------------------------

@test "fallback comment: notes no acceptance criteria found" {
    comment=$(_qa_build_comment "0" "qa-pass" "make test" "" "no")
    echo "$comment" | grep -q "No acceptance criteria found"
}

@test "fallback comment: still includes Phase 4 and Verdict" {
    comment=$(_qa_build_comment "0" "qa-pass" "make test" "" "no")
    echo "$comment" | grep -q "Phase 4: validation_cmd"
    echo "$comment" | grep -q "Verdict:"
}

@test "fallback comment: no validation_cmd shows Phase 4 skipped" {
    comment=$(_qa_build_comment "0" "qa-pass" "" "" "no")
    echo "$comment" | grep -q "Phase 4 skipped"
}

@test "fallback comment: has_ac=yes but empty ac_list shows fallback text" {
    comment=$(_qa_build_comment "0" "qa-pass" "make test" "" "yes")
    echo "$comment" | grep -q "No acceptance criteria found"
}
