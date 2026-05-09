#!/usr/bin/env bats
# Tests for the untracked-data classifier in lib/failure_classifier.sh.

setup() {
    LOOP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/runner.sh
    source "$LOOP_ROOT/lib/runner.sh"
    # shellcheck source=../lib/failure_classifier.sh
    source "$LOOP_ROOT/lib/failure_classifier.sh"
}

@test "matches FileNotFoundError on .npy data" {
    text="FileNotFoundError: [Errno 2] No such file or directory: 'data/processed/vanco/X_train.npy'"
    run loop_is_missing_untracked_data "$text"
    [ "$status" -eq 0 ]
}

@test "matches model checkpoint .pt files" {
    text="No such file or directory: '../models/checkpoints/best.pt'"
    run loop_is_missing_untracked_data "$text"
    [ "$status" -eq 0 ]
}

@test "matches /data/ directory hint without specific extension" {
    text="No such file or directory: 'project/data/raw_inputs.bin'"
    run loop_is_missing_untracked_data "$text"
    [ "$status" -eq 0 ]
}

@test "does NOT match ModuleNotFoundError (transient infra failure)" {
    text="ModuleNotFoundError: No module named 'providers.session_manager'"
    run loop_is_missing_untracked_data "$text"
    [ "$status" -ne 0 ]
}

@test "does NOT match plain FileNotFoundError without data signal" {
    text="FileNotFoundError: [Errno 2] No such file or directory: 'requirements.txt'"
    run loop_is_missing_untracked_data "$text"
    [ "$status" -ne 0 ]
}

@test "does NOT match unrelated stderr" {
    text="RuntimeError: agent tried to write to read-only resource"
    run loop_is_missing_untracked_data "$text"
    [ "$status" -ne 0 ]
}

@test "does NOT match empty input" {
    run loop_is_missing_untracked_data ""
    [ "$status" -ne 0 ]
}

@test "extract_missing_path pulls path from FileNotFoundError" {
    text="FileNotFoundError: [Errno 2] No such file or directory: 'data/x.npy'"
    run loop_extract_missing_path "$text"
    [ "$output" = "data/x.npy" ]
}
