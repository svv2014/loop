#!/usr/bin/env bats
# tests/failure_category.bats — unit + integration tests for lib/failure_category.sh.
#
# No real network or CLI required.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/failure_category.sh
    source "$REPO_ROOT/lib/failure_category.sh"
}

# ── Category: budget ──────────────────────────────────────────────────────────

@test "budget: 'daily.budget' text → budget" {
    run loop_failure_category "Error: daily.budget limit reached" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "budget: 'budget cap' text → budget" {
    run loop_failure_category "Operation aborted: budget cap exceeded" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "budget: 'budget exhausted' text → budget" {
    run loop_failure_category "FATAL budget exhausted for project" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "budget: 'LOOP_DAILY_BUDGET' text → budget" {
    run loop_failure_category "LOOP_DAILY_BUDGET cap hit, aborting" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

# ── Category: network ─────────────────────────────────────────────────────────

@test "network: HTTP 503 → network" {
    run loop_failure_category "Request failed: HTTP 503 Service Unavailable" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: timeout text → network" {
    run loop_failure_category "Error: operation timeout after 30s" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: timed out text → network" {
    run loop_failure_category "Connection timed out" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: ConnectionRefused → network" {
    run loop_failure_category "ConnectionRefused: could not reach api.example.com" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: TimeoutError → network" {
    run loop_failure_category "TimeoutError: socket timed out" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: 429 → network" {
    run loop_failure_category "Error 429: Too Many Requests" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: rate limit → network" {
    run loop_failure_category "Blocked due to rate limit policy" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

# ── Category: git_conflict ────────────────────────────────────────────────────

@test "git_conflict: CONFLICT ( → git_conflict" {
    run loop_failure_category "CONFLICT (content): Merge conflict in lib/foo.sh" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "git_conflict: Merge conflict → git_conflict" {
    run loop_failure_category "Merge conflict detected in scripts/bar.sh" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "git_conflict: rebase.*conflict → git_conflict" {
    run loop_failure_category "error: rebase aborted due to conflict in file" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "git_conflict: <<<<<<< HEAD → git_conflict" {
    run loop_failure_category "<<<<<<< HEAD" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

# ── Category: model_error ─────────────────────────────────────────────────────

@test "model_error: claude API error → model_error" {
    run loop_failure_category "claude exited with API error: invalid response" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "model_error: claude invalid_request → model_error" {
    run loop_failure_category "claude returned invalid_request" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "model_error: claude overloaded → model_error" {
    run loop_failure_category "claude: overloaded, try again later" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "model_error: anthropic.*error → model_error" {
    run loop_failure_category "anthropic API error: bad gateway" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "model_error: prompt is too long → model_error" {
    run loop_failure_category "Error: prompt is too long (128000 tokens)" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

# ── Category: tool_error ──────────────────────────────────────────────────────

@test "tool_error: 'gh: ' prefix → tool_error" {
    run loop_failure_category "gh: error: pull request not found" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: 'git: ' prefix → tool_error" {
    run loop_failure_category "git: fatal: not a git repository" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: 'jq: ' prefix → tool_error" {
    run loop_failure_category "jq: error: null has no field" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: command not found → tool_error" {
    run loop_failure_category "bash: bats: command not found" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: non-zero exit with unknown text → tool_error" {
    run loop_failure_category "some unrecognised error output" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

# ── Category: unknown ─────────────────────────────────────────────────────────

@test "unknown: empty text with rc=0 → unknown" {
    run loop_failure_category "" 0
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "unknown: no matching text with rc=0 → unknown" {
    run loop_failure_category "some benign output with exit 0" 0
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

# ── Priority: budget wins over network ────────────────────────────────────────

@test "priority: budget before network — budget keyword wins" {
    run loop_failure_category "daily.budget cap hit after HTTP 503" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

# ── Integration: handler failure path emits correct failure_reason ─────────────

@test "integration: network stderr produces failure_reason=network in bounty_report call" {
    local captured="$BATS_TMPDIR/bounty-capture.txt"
    rm -f "$captured"

    # Mock bounty_report to record args
    bounty_report() {
        printf '%s\n' "$@" > "$captured"
    }
    export -f bounty_report 2>/dev/null || true

    local _stderr="Request failed: HTTP 503 Service Unavailable"
    local _failure_reason
    _failure_reason=$(loop_failure_category "$_stderr" 1)
    bounty_report "dev_failed" role=dev project=test failure_reason="$_failure_reason"

    grep -q "^failure_reason=network$" "$captured"
}
