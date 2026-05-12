#!/usr/bin/env bats
# tests/qa-baseline.bats — unit tests for lib/qa-baseline.sh diff routines.
#
# Uses static TAP fixtures written inline — no real test runs.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/qa-baseline.sh
    source "$REPO_ROOT/lib/qa-baseline.sh"

    # Scratch dir for fixture files
    FIXTURE_DIR="$BATS_TMPDIR/qa-baseline-fixtures-$$"
    mkdir -p "$FIXTURE_DIR"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

write_tap() {
    # write_tap <file> <content>
    printf '%s\n' "$2" > "$1"
}

# ---------------------------------------------------------------------------
# qa_baseline_cache_path
# ---------------------------------------------------------------------------

@test "cache_path: produces path under LOOP_CACHE_DIR with slug and sha" {
    export LOOP_CACHE_DIR="$BATS_TMPDIR/cache-$$"
    result=$(qa_baseline_cache_path "myslug" "abc123")
    [[ "$result" == "${BATS_TMPDIR}/cache-$$/qa-baseline-myslug-abc123.tap" ]]
}

@test "cache_path: different slugs produce different paths" {
    export LOOP_CACHE_DIR="/tmp/c"
    r1=$(qa_baseline_cache_path "slug-a" "sha1")
    r2=$(qa_baseline_cache_path "slug-b" "sha1")
    [ "$r1" != "$r2" ]
}

@test "cache_path: different shas produce different paths" {
    export LOOP_CACHE_DIR="/tmp/c"
    r1=$(qa_baseline_cache_path "slug" "sha1")
    r2=$(qa_baseline_cache_path "slug" "sha2")
    [ "$r1" != "$r2" ]
}

# ---------------------------------------------------------------------------
# qa_baseline_parse_failing
# ---------------------------------------------------------------------------

@test "parse_failing: returns failing test names from TAP" {
    write_tap "$FIXTURE_DIR/t.tap" "TAP version 13
1..3
ok 1 - passes fine
not ok 2 - fails here
ok 3 - also passes"
    result=$(qa_baseline_parse_failing "$FIXTURE_DIR/t.tap")
    [ "$result" = "fails here" ]
}

@test "parse_failing: returns multiple failing names" {
    write_tap "$FIXTURE_DIR/t.tap" "TAP version 13
1..3
not ok 1 - first failure
not ok 2 - second failure
ok 3 - passes"
    count=$(qa_baseline_parse_failing "$FIXTURE_DIR/t.tap" | wc -l | tr -d ' ')
    [ "$count" = "2" ]
}

@test "parse_failing: returns empty for all-passing TAP" {
    write_tap "$FIXTURE_DIR/t.tap" "TAP version 13
1..2
ok 1 - first passes
ok 2 - second passes"
    result=$(qa_baseline_parse_failing "$FIXTURE_DIR/t.tap")
    [ -z "$result" ]
}

@test "parse_failing: strips TODO annotation from test name" {
    write_tap "$FIXTURE_DIR/t.tap" "not ok 1 - flaky test # TODO fix later"
    result=$(qa_baseline_parse_failing "$FIXTURE_DIR/t.tap")
    [ "$result" = "flaky test" ]
}

@test "parse_failing: strips SKIP annotation from test name" {
    write_tap "$FIXTURE_DIR/t.tap" "not ok 1 - skipped test # SKIP not ready"
    result=$(qa_baseline_parse_failing "$FIXTURE_DIR/t.tap")
    [ "$result" = "skipped test" ]
}

@test "parse_failing: returns empty for non-TAP file" {
    write_tap "$FIXTURE_DIR/t.tap" "this is not tap output at all
just some random text"
    result=$(qa_baseline_parse_failing "$FIXTURE_DIR/t.tap")
    [ -z "$result" ]
}

@test "parse_failing: returns empty for missing file" {
    result=$(qa_baseline_parse_failing "$FIXTURE_DIR/nonexistent.tap")
    [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# qa_baseline_diff — core logic
# ---------------------------------------------------------------------------

@test "diff: identical failure sets → no new failures → exit 0" {
    write_tap "$FIXTURE_DIR/baseline.tap" "TAP version 13
1..3
ok 1 - passes on main
not ok 2 - flaky on main
ok 3 - passes on main too"
    write_tap "$FIXTURE_DIR/pr.tap" "TAP version 13
1..3
ok 1 - passes on main
not ok 2 - flaky on main
ok 3 - passes on main too"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PRE_EXISTING:flaky on main"
    ! echo "$output" | grep -q "NEW_FAILURE:"
}

@test "diff: PR adds new failure → new failure reported → exit 1" {
    write_tap "$FIXTURE_DIR/baseline.tap" "TAP version 13
1..2
ok 1 - test alpha
ok 2 - test beta"
    write_tap "$FIXTURE_DIR/pr.tap" "TAP version 13
1..2
ok 1 - test alpha
not ok 2 - test beta"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "NEW_FAILURE:test beta"
    ! echo "$output" | grep -q "PRE_EXISTING:"
}

@test "diff: pre-existing failure not counted as new" {
    write_tap "$FIXTURE_DIR/baseline.tap" "not ok 1 - old flake"
    write_tap "$FIXTURE_DIR/pr.tap" "not ok 1 - old flake"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PRE_EXISTING:old flake"
    ! echo "$output" | grep -q "NEW_FAILURE:"
}

@test "diff: test fixed in PR reported as FIXED" {
    write_tap "$FIXTURE_DIR/baseline.tap" "not ok 1 - old bug"
    write_tap "$FIXTURE_DIR/pr.tap" "ok 1 - old bug"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FIXED:old bug"
    ! echo "$output" | grep -q "NEW_FAILURE:"
    ! echo "$output" | grep -q "PRE_EXISTING:"
}

@test "diff: mix of new, pre-existing, and fixed failures" {
    write_tap "$FIXTURE_DIR/baseline.tap" "TAP version 13
1..4
not ok 1 - old flake
not ok 2 - another old flake
ok 3 - was passing
ok 4 - old bug being fixed"
    write_tap "$FIXTURE_DIR/pr.tap" "TAP version 13
1..4
not ok 1 - old flake
ok 2 - another old flake
not ok 3 - was passing
ok 4 - old bug being fixed"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "NEW_FAILURE:was passing"
    echo "$output" | grep -q "PRE_EXISTING:old flake"
    echo "$output" | grep -q "FIXED:another old flake"
}

@test "diff: all passing baseline and PR → no output, exit 0" {
    write_tap "$FIXTURE_DIR/baseline.tap" "ok 1 - all good
ok 2 - also good"
    write_tap "$FIXTURE_DIR/pr.tap" "ok 1 - all good
ok 2 - also good"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "diff: non-TAP file returns exit 2" {
    write_tap "$FIXTURE_DIR/baseline.tap" "not tap content"
    write_tap "$FIXTURE_DIR/pr.tap" "also not tap"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 2 ]
}

@test "diff: valid baseline but non-TAP PR returns exit 2" {
    write_tap "$FIXTURE_DIR/baseline.tap" "ok 1 - passes"
    write_tap "$FIXTURE_DIR/pr.tap" "random non-tap output"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 2 ]
}

@test "diff: empty files treated as valid TAP with no tests → exit 0" {
    write_tap "$FIXTURE_DIR/baseline.tap" ""
    write_tap "$FIXTURE_DIR/pr.tap" ""

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    # Both empty → no TAP lines → exit 2 (not valid TAP)
    [ "$status" -eq 2 ]
}

@test "diff: TODO annotations stripped before comparison" {
    write_tap "$FIXTURE_DIR/baseline.tap" "not ok 1 - flaky test # TODO fix later"
    write_tap "$FIXTURE_DIR/pr.tap" "not ok 1 - flaky test # TODO fix later"

    run qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PRE_EXISTING:flaky test"
}

# ---------------------------------------------------------------------------
# qa_baseline_diff — qa-pass / qa-fail mapping
# ---------------------------------------------------------------------------

@test "qa-handler decision: no new failures → qa-pass" {
    write_tap "$FIXTURE_DIR/baseline.tap" "not ok 1 - pre-existing flake"
    write_tap "$FIXTURE_DIR/pr.tap" "not ok 1 - pre-existing flake"

    diff_output=$(qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap" || true)
    new_count=$(echo "$diff_output" | grep -c "^NEW_FAILURE:" || true)
    verdict="qa-pass"
    [ "$new_count" -gt 0 ] && verdict="qa-fail"
    [ "$verdict" = "qa-pass" ]
}

@test "qa-handler decision: new failure present → qa-fail" {
    write_tap "$FIXTURE_DIR/baseline.tap" "ok 1 - clean baseline"
    write_tap "$FIXTURE_DIR/pr.tap" "not ok 1 - clean baseline"

    diff_output=$(qa_baseline_diff "$FIXTURE_DIR/baseline.tap" "$FIXTURE_DIR/pr.tap" || true)
    new_count=$(echo "$diff_output" | grep -c "^NEW_FAILURE:" || true)
    verdict="qa-pass"
    [ "$new_count" -gt 0 ] && verdict="qa-fail"
    [ "$verdict" = "qa-fail" ]
}
