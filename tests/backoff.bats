#!/usr/bin/env bats
# tests/backoff.bats — coverage for lib/backoff.sh (#153).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_BACKOFF_DIR="$BATS_TMPDIR/backoff-$$"
    rm -rf "$LOOP_BACKOFF_DIR"
    mkdir -p "$LOOP_BACKOFF_DIR"
    export LOOP_BACKOFF_SCHEDULE="0 30 60 120 300"
    export LOOP_BACKOFF_MAX_AT_CAP=3

    # shellcheck source=../lib/backoff.sh
    source "$REPO_ROOT/lib/backoff.sh"
}

teardown() {
    rm -rf "$LOOP_BACKOFF_DIR"
}

@test "fresh ticket is eligible" {
    run loop_backoff_check ppl 100 dev
    [ "$status" -eq 0 ]
}

@test "first failure: count=1, delay=30s, blocks check" {
    local count; count=$(loop_backoff_record_failure ppl 100 dev "test")
    [ "$count" -eq 1 ]

    # Now in cooldown — check should fail.
    run loop_backoff_check ppl 100 dev
    [ "$status" -eq 1 ]

    # Verify count tracked correctly.
    [ "$(loop_backoff_count ppl 100 dev)" -eq 1 ]
}

@test "exponential progression: 30 → 60 → 120 → 300 → 300" {
    [ "$(_loop_backoff_delay_for_attempt 1)" -eq 30 ]
    [ "$(_loop_backoff_delay_for_attempt 2)" -eq 60 ]
    [ "$(_loop_backoff_delay_for_attempt 3)" -eq 120 ]
    [ "$(_loop_backoff_delay_for_attempt 4)" -eq 300 ]
    [ "$(_loop_backoff_delay_for_attempt 5)" -eq 300 ]
    [ "$(_loop_backoff_delay_for_attempt 99)" -eq 300 ]
}

@test "after cooldown elapses, ticket becomes eligible again" {
    loop_backoff_record_failure ppl 100 dev "test"

    # Backdate next_eligible to 1 minute ago.
    local path
    path=$(_loop_backoff_path ppl 100 dev)
    local now; now=$(date +%s)
    sed -i.bak "s/^next_eligible:.*/next_eligible:$((now - 60))/" "$path"
    rm -f "$path.bak"

    run loop_backoff_check ppl 100 dev
    [ "$status" -eq 0 ]
}

@test "loop_backoff_clear removes state" {
    loop_backoff_record_failure ppl 100 dev "test"
    [ "$(loop_backoff_count ppl 100 dev)" -eq 1 ]

    loop_backoff_clear ppl 100 dev
    [ "$(loop_backoff_count ppl 100 dev)" -eq 0 ]

    run loop_backoff_check ppl 100 dev
    [ "$status" -eq 0 ]
}

@test "per-(slug, num, stage) isolation" {
    loop_backoff_record_failure ppl 100 dev "test"
    [ "$(loop_backoff_count ppl 100 dev)" -eq 1 ]

    # Different stage → independent counter.
    [ "$(loop_backoff_count ppl 100 review)" -eq 0 ]
    # Different num → independent counter.
    [ "$(loop_backoff_count ppl 101 dev)" -eq 0 ]
    # Different slug → independent counter.
    [ "$(loop_backoff_count loop 100 dev)" -eq 0 ]
}

@test "at-cap tracking: exhaustion threshold for blocked promotion" {
    # 3 failures: count=3, delay=120s (last non-cap step) → at_cap=0
    loop_backoff_record_failure ppl 100 dev "f1"
    loop_backoff_record_failure ppl 100 dev "f2"
    loop_backoff_record_failure ppl 100 dev "f3"
    [ "$(loop_backoff_at_cap_count ppl 100 dev)" -eq 0 ]

    # 4th failure: count=4, delay=300s (cap reached) → at_cap=1
    loop_backoff_record_failure ppl 100 dev "f4"
    [ "$(loop_backoff_at_cap_count ppl 100 dev)" -eq 1 ]

    # 5th: at_cap=2
    loop_backoff_record_failure ppl 100 dev "f5"
    [ "$(loop_backoff_at_cap_count ppl 100 dev)" -eq 2 ]

    # 6th: at_cap=3 — reaches LOOP_BACKOFF_MAX_AT_CAP, reconciler should
    # promote to `blocked` (verified in reconcile_backoff_exhausted tests).
    loop_backoff_record_failure ppl 100 dev "f6"
    [ "$(loop_backoff_at_cap_count ppl 100 dev)" -eq 3 ]
}

@test "filesystem-safe slug sanitisation (dots, slashes)" {
    # example.com has a dot; the helper must not produce a path that breaks.
    loop_backoff_record_failure example.com 10 dev "test"
    [ "$(loop_backoff_count example.com 10 dev)" -eq 1 ]
    # Round-trip works: clear, then re-check.
    loop_backoff_clear example.com 10 dev
    [ "$(loop_backoff_count example.com 10 dev)" -eq 0 ]
}
