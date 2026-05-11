#!/usr/bin/env bats
# tests/failure_category.bats — unit + integration tests for lib/failure_category.sh.
#
# No real network or CLI required.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/failure_category.sh
    source "$REPO_ROOT/lib/failure_category.sh"
}

# ─── Unit: one fixture per category ───────────────────────────────────────────

@test "budget: daily.budget in text → budget" {
    run loop_failure_category "Error: daily.budget cap reached, aborting" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

@test "network: HTTP 503 in text → network" {
    run loop_failure_category "Error: received HTTP 503 Service Unavailable from upstream" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: 429 rate limit in text → network" {
    run loop_failure_category "HTTP 429 Too Many Requests: rate limit exceeded" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "network: ConnectionRefused in text → network" {
    run loop_failure_category "ConnectionRefused: could not reach api endpoint" 1
    [ "$status" -eq 0 ]
    [ "$output" = "network" ]
}

@test "git_conflict: CONFLICT marker in text → git_conflict" {
    run loop_failure_category "Auto-merging foo.sh
CONFLICT (content): Merge conflict in foo.sh
Automatic merge failed; fix conflicts and then commit." 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "git_conflict: <<<<<<< HEAD marker in text → git_conflict" {
    run loop_failure_category "<<<<<<< HEAD
some content
=======" 1
    [ "$status" -eq 0 ]
    [ "$output" = "git_conflict" ]
}

@test "model_error: anthropic error in text → model_error" {
    run loop_failure_category "anthropic.APIError: invalid_request_error: prompt is too long" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "model_error: prompt is too long → model_error" {
    run loop_failure_category "Error: prompt is too long (120000 tokens, limit 100000)" 1
    [ "$status" -eq 0 ]
    [ "$output" = "model_error" ]
}

@test "tool_error: gh: error in text → tool_error" {
    run loop_failure_category "gh: pull request not found: '999'" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "tool_error: command not found in text → tool_error" {
    run loop_failure_category "jq: command not found" 1
    [ "$status" -eq 0 ]
    [ "$output" = "tool_error" ]
}

@test "unknown: unrecognised error text → unknown" {
    run loop_failure_category "SomethingWentWrong: unexpected state at line 42" 1
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "unknown: empty text → unknown" {
    run loop_failure_category "" 1
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

# ─── Priority ordering ─────────────────────────────────────────────────────────

@test "budget takes priority over network when both match" {
    run loop_failure_category "HTTP 503: daily.budget exhausted, aborting" 1
    [ "$status" -eq 0 ]
    [ "$output" = "budget" ]
}

# ─── Integration: bounty payload contains failure_reason ──────────────────────
# Simulate the qa-handler failure path: agent stderr contains a network error;
# assert the emitted JSON payload carries failure_reason=network.

@test "integration: network stderr produces failure_reason=network in bounty payload" {
    # Stub curl so bounty_report captures the payload instead of sending it.
    local captured_payload="$BATS_TMPDIR/bounty_payload.json"

    curl() {
        # Extract the -d <payload> argument
        local prev=""
        for arg in "$@"; do
            if [ "$prev" = "-d" ]; then
                printf '%s' "$arg" > "$captured_payload"
            fi
            prev="$arg"
        done
        return 0
    }
    export -f curl 2>/dev/null || true

    # Source bounty.sh after stubbing curl.
    source "$REPO_ROOT/lib/bounty.sh"

    # Simulate capturing agent stderr and classifying it.
    local _agent_tail="Error: ConnectionReset while sending request to api endpoint"
    local _fc
    _fc=$(loop_failure_category "$_agent_tail") || _fc=unknown

    bounty_report "qa_fail" role=qa project=test-proj pr_num=42 failure_reason="$_fc"

    # Verify payload file was written.
    [ -f "$captured_payload" ]

    # Verify failure_reason=network in the JSON.
    local reason
    reason=$(python3 -c "import json,sys; d=json.load(open('$captured_payload')); print(d.get('failure_reason',''))")
    [ "$reason" = "network" ]
}
