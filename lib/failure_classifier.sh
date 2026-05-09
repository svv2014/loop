#!/usr/bin/env bash
# lib/failure_classifier.sh — classify handler failures as transient (infra)
# or non-transient (spec/logic).
#
# Transient: Python ImportError/ModuleNotFoundError/ConnectionError/TimeoutError,
# plus anything _loop_is_recoverable already matches (auth, rate-limit, 5xx,
# network).  These should NOT burn the per-issue retry counter.
#
# Non-transient: everything else (RuntimeError, bad spec, agent logic failure).
#
# Usage:
#   source "$LOOP_ROOT/lib/failure_classifier.sh"
#   if loop_is_transient_failure "$stderr_text" "$exit_code"; then ...
#   sig=$(loop_failure_signature "$stderr_text")

# Requires lib/runner.sh to be sourced first (for _loop_is_recoverable).

# loop_is_transient_failure <stderr_text> <exit_code>
# Returns 0 (true) for transient infra failures, 1 (false) otherwise.
loop_is_transient_failure() {
    local text="$1"
    local rc="${2:-1}"
    [ "$rc" -eq 0 ] && return 1
    [ -z "$text" ] && return 1
    _loop_is_recoverable "$text" && return 0
    echo "$text" | grep -qE '(ImportError|ModuleNotFoundError|ConnectionError|TimeoutError|ConnectionRefusedError)' && return 0
    return 1
}

# loop_failure_signature <stderr_text>
# Extracts and prints a short signature token from the stderr text (first match).
# Returns empty string if no known pattern is found.
loop_failure_signature() {
    local text="$1"
    echo "$text" | grep -oE '(ImportError|ModuleNotFoundError|ConnectionError|TimeoutError|429|5[0-9]{2}|rate limit|timeout)' | head -1
}
