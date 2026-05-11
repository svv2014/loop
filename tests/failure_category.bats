#!/usr/bin/env bats
# tests/failure_category.bats — unit tests for lib/failure_category.sh
# and integration: bounty_report emits failure_reason in *_failed payloads.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/failure_category.sh
    source "$REPO_ROOT/lib/failure_category.sh"
}

# ─── loop_failure_category — one fixture per category ────────────────────────

@test "budget: daily.budget text → budget" {
    run loop_failure_category "Error: daily.budget exceeded for project" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "budget: budget cap text → budget" {
    run loop_failure_category "Stopping: budget cap reached" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "network: HTTP 503 → network" {
    run loop_failure_category "Error: received HTTP 503 from upstream" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: rate limit → network" {
    run loop_failure_category "Error: rate limit exceeded, please retry later" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: 429 → network" {
    run loop_failure_category "HTTP 429 Too Many Requests" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: timeout → network" {
    run loop_failure_category "operation timed out after 30 seconds" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "git_conflict: CONFLICT marker → git_conflict" {
    run loop_failure_category "CONFLICT (content): Merge conflict in src/foo.sh" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "git_conflict: <<<<<<< HEAD → git_conflict" {
    run loop_failure_category "<<<<<<< HEAD" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "model_error: prompt is too long → model_error" {
    run loop_failure_category "Error: prompt is too long for this model" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "model_error: anthropic.*error → model_error" {
    run loop_failure_category "anthropic API error: overloaded_error" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "tool_error: gh: command → tool_error" {
    run loop_failure_category "gh: unknown command \"labell\"" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: command not found → tool_error" {
    run loop_failure_category "bats: command not found" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: non-zero exit with no pattern → tool_error" {
    run loop_failure_category "some unrecognised failure output" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "unknown: empty text with exit 0 → unknown" {
    run loop_failure_category "" 0
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "budget wins over network when both match" {
    run loop_failure_category "budget cap: HTTP 503 upstream" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "network wins over git_conflict when both match" {
    run loop_failure_category "timeout while fetching: <<<<<<< HEAD appears in diff" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

# ─── Integration: bounty_report emits failure_reason field ───────────────────

@test "integration: bounty_report failure_reason=network appears in JSON payload" {
    # Set up mock curl so we can capture the payload.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-curl.sh" "$BATS_TMPDIR/bin/curl"
    chmod +x "$BATS_TMPDIR/bin/curl"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # shellcheck source=../lib/bounty.sh
    source "$REPO_ROOT/lib/bounty.sh"

    PAYLOAD_FILE="$BATS_TMPDIR/payload.json"
    export CURL_PAYLOAD_FILE="$PAYLOAD_FILE"
    export BOUNTY_URL="http://127.0.0.1:18792"
    export BOUNTY_TIMEOUT="1"
    export BOUNTY_API_VERSION="1.0"

    # Simulate a network-failure stderr, classify it, emit the event.
    _stderr="Error: HTTP 503 gateway timeout from upstream API"
    _reason=$(loop_failure_category "$_stderr" 1)
    [ "$_reason" = "network" ]

    bounty_report "review_failed" project=myapp pr_num=7 detail="attempt 1/2" failure_reason="$_reason"

    [ -f "$PAYLOAD_FILE" ]
    run python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('failure_reason','MISSING'))" < "$PAYLOAD_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}
