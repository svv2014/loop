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

# loop_is_missing_untracked_data <stderr_text>
# Returns 0 (true) if the failure looks like the worker is asking for files
# that don't exist in its worktree. Typical pattern: ML/data projects whose
# preprocessed arrays / model checkpoints / large fixtures are gitignored
# and therefore absent from the fresh worktree.
#
# Heuristic: stderr mentions a missing-file diagnostic AND references a path
# that looks like runtime data (one of common extensions or directory hints).
# Conservative — false positives are worse than false negatives here because
# the consequence is permanently blocking the issue with an explanatory
# comment, not transparently retrying.
loop_is_missing_untracked_data() {
    local text="$1"
    [ -z "$text" ] && return 1
    echo "$text" | grep -qE '(FileNotFoundError|No such file or directory|cannot find the file|does not exist)' || return 1
    echo "$text" | grep -qE '(\.npy|\.npz|\.pt|\.pth|\.ckpt|\.h5|\.hdf5|\.parquet|\.pkl|\.joblib|\.bin|/data/|/models/|/checkpoints/|/fixtures/)' || return 1
    return 0
}

# loop_extract_missing_path <stderr_text>
# Best-effort: pull the offending path out of a "FileNotFoundError" or
# "No such file or directory" line. Empty string if nothing recognisable.
loop_extract_missing_path() {
    local text="$1"
    {
        echo "$text" | grep -oE "FileNotFoundError[^']*'[^']+'" | grep -oE "'[^']+'" | tr -d "'" | head -1
        echo "$text" | grep -oE "No such file or directory[^A-Za-z0-9_/.-]*[A-Za-z0-9_./-]+" | grep -oE "[A-Za-z0-9_./-]+$" | head -1
    } | grep -v '^$' | head -1
}
