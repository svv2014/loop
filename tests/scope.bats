#!/usr/bin/env bats
# tests/scope.bats — unit tests for lib/scope.sh::loop_check_scope.
#
# No network or gh CLI required. Pure logic tests against the Python parser.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/scope.sh
    source "$REPO_ROOT/lib/scope.sh"
}

# ─── no scope declared ────────────────────────────────────────────────────────

@test "no scope declaration → all files pass" {
    body="## Summary
Just a regular issue with no file scope."
    files="src/main.py
README.md"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "empty staged files → passes (nothing to check)" {
    body="## Files in scope
tests/foo.py"
    run loop_check_scope "$body" ""
    [ "$status" -eq 0 ]
}

# ─── Files in scope (allowlist) ───────────────────────────────────────────────

@test "allowlist: file in scope → passes" {
    body="## Files in scope
tests/foo.py"
    files="tests/foo.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "allowlist: file outside scope → violation" {
    body="## Files in scope
tests/foo.py"
    files="src/main.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "src/main.py" ]
}

@test "allowlist: glob pattern matches → passes" {
    body="## Files in scope
tests/*"
    files="tests/foo.py
tests/bar.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "allowlist: glob pattern — non-matching file → violation" {
    body="## Files in scope
tests/*"
    files="tests/foo.py
src/helper.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "src/helper.py" ]
}

@test "allowlist: multiple patterns — all files covered → passes" {
    body="## Files in scope
tests/*
lib/scope.sh"
    files="tests/foo.py
lib/scope.sh"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
}

# ─── Files NOT in scope (denylist) ────────────────────────────────────────────

@test "denylist: denied file → violation" {
    body="## Files NOT in scope
backtest/v5_rules.py"
    files="backtest/v5_rules.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "backtest/v5_rules.py" ]
}

@test "denylist: non-denied file → passes" {
    body="## Files NOT in scope
backtest/v5_rules.py"
    files="tests/test_scope.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "denylist overrides allowlist: file in both → violation" {
    body="## Files in scope
backtest/*
## Files NOT in scope
backtest/v5_rules.py"
    files="backtest/v5_rules.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "backtest/v5_rules.py" ]
}

@test "denylist: glob denies directory tree → violation" {
    body="## Files NOT in scope
src/*"
    files="src/main.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "src/main.py" ]
}

# ─── No production code heuristic ─────────────────────────────────────────────

@test "no-prod heuristic: test file → passes" {
    body="## Summary
No production code was modified. Tests only."
    files="tests/test_foo.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no-prod heuristic: bats file → passes" {
    body="No production code changes in this issue."
    files="tests/scope.bats"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
}

@test "no-prod heuristic: test_*.py basename → passes" {
    body="No production code was modified."
    files="lib/tests/test_scope.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
}

@test "no-prod heuristic: production file → violation" {
    body="No Production Code was modified."
    files="src/main.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "src/main.py" ]
}

@test "no-prod heuristic: mixed staged files — only prod file blocked" {
    body="No production code modified."
    files="tests/test_foo.py
src/helper.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "src/helper.py" ]
}

@test "no-prod heuristic: case-insensitive match" {
    body="NO PRODUCTION CODE touched here."
    files="lib/utils.sh"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    [ "$output" = "lib/utils.sh" ]
}

# ─── edge cases ───────────────────────────────────────────────────────────────

@test "multiple violations → all printed" {
    body="## Files in scope
tests/*"
    files="tests/foo.py
src/a.py
src/b.py"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "src/a.py"
    echo "$output" | grep -q "src/b.py"
}

@test "section with blank lines and comments is parsed correctly" {
    body="## Files in scope

tests/scope.bats

# this is a comment, ignored
"
    files="tests/scope.bats"
    run loop_check_scope "$body" "$files"
    [ "$status" -eq 0 ]
}
