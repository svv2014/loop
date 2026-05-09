#!/usr/bin/env bats
# tests/failure_classifier.bats — unit tests for lib/failure_classifier.sh.
#
# No real network or CLI required. _loop_is_recoverable is stubbed.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Stub _loop_is_recoverable (normally comes from lib/runner.sh).
    # Returns 0 when text matches known recovery signals (401, 429, 5xx, etc.).
    _loop_is_recoverable() {
        local text="$1"
        echo "$text" | grep -qiE \
            '(\b401\b|403[^0-9]*auth|auth[^0-9]*403|\b429\b|[^0-9]5[0-9]{2}[^0-9]|rate limit|timeout|connection refused|econnreset|service unavailable)'
    }
    export -f _loop_is_recoverable 2>/dev/null || true

    # shellcheck source=../lib/failure_classifier.sh
    source "$REPO_ROOT/lib/failure_classifier.sh"
}

teardown() {
    unset -f _loop_is_recoverable 2>/dev/null || true
}

# ─── loop_is_transient_failure ────────────────────────────────────────────────

@test "ImportError → transient (returns 0)" {
    run loop_is_transient_failure "Traceback: ImportError: No module named foo" 1
    [ "$status" -eq 0 ]
}

@test "ModuleNotFoundError → transient (returns 0)" {
    run loop_is_transient_failure "ModuleNotFoundError: No module named 'providers.session_manager'" 1
    [ "$status" -eq 0 ]
}

@test "ConnectionError → transient (returns 0)" {
    run loop_is_transient_failure "ConnectionError: failed to connect to api.example.com" 1
    [ "$status" -eq 0 ]
}

@test "TimeoutError → transient (returns 0)" {
    run loop_is_transient_failure "TimeoutError: operation timed out after 30s" 1
    [ "$status" -eq 0 ]
}

@test "ConnectionRefusedError → transient (returns 0)" {
    run loop_is_transient_failure "ConnectionRefusedError: [Errno 111] Connection refused" 1
    [ "$status" -eq 0 ]
}

@test "_loop_is_recoverable match (rate limit) → transient (returns 0)" {
    run loop_is_transient_failure "error: rate limit exceeded, retry later" 1
    [ "$status" -eq 0 ]
}

@test "_loop_is_recoverable match (429) → transient (returns 0)" {
    run loop_is_transient_failure "HTTP 429 Too Many Requests" 1
    [ "$status" -eq 0 ]
}

@test "plain RuntimeError: bad spec → non-transient (returns 1)" {
    run loop_is_transient_failure "RuntimeError: bad spec — missing acceptance criteria" 1
    [ "$status" -eq 1 ]
}

@test "exit-code 0 → non-transient regardless of text (sanity check)" {
    run loop_is_transient_failure "ImportError: something" 0
    [ "$status" -eq 1 ]
}

@test "empty stderr → non-transient (returns 1)" {
    run loop_is_transient_failure "" 1
    [ "$status" -eq 1 ]
}

# ─── loop_failure_signature ───────────────────────────────────────────────────

@test "loop_failure_signature extracts ImportError" {
    run loop_failure_signature "Traceback: ImportError: No module named foo"
    [ "$status" -eq 0 ]
    [ "$output" = "ImportError" ]
}

@test "loop_failure_signature extracts 429" {
    run loop_failure_signature "HTTP 429 Too Many Requests"
    [ "$status" -eq 0 ]
    [ "$output" = "429" ]
}

@test "loop_failure_signature returns empty for unknown text" {
    run loop_failure_signature "SyntaxError: unexpected token at line 42"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
