#!/usr/bin/env bats
# tests/bounty-detail.bats — unit tests for bounty_truncate_detail helper.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/bounty.sh
    source "$REPO_ROOT/lib/bounty.sh"
}

# ---------------------------------------------------------------------------
# (a) multi-line input >200 chars: collapse newlines, truncate to ≤200
# ---------------------------------------------------------------------------

@test "bounty_truncate_detail: multi-line >200 chars has no newlines and length ≤200" {
    local input=""
    for i in $(seq 1 20); do
        input="${input}diagnostic output line ${i} with agent error context here"$'\n'
    done

    run bounty_truncate_detail "$input"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "${#output}" -le 200 ]
    # no embedded newlines
    local stripped
    stripped="$(printf '%s' "$output" | tr -d '\n')"
    [ "$output" = "$stripped" ]
}

# ---------------------------------------------------------------------------
# (b) empty input returns empty string
# ---------------------------------------------------------------------------

@test "bounty_truncate_detail: empty input returns empty output" {
    run bounty_truncate_detail ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# (c) input already ≤200 chars passes through (trimmed, no newlines added)
# ---------------------------------------------------------------------------

@test "bounty_truncate_detail: short input ≤200 chars is returned intact" {
    local input="agent exited with code 1 on step 3"
    run bounty_truncate_detail "$input"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "${#output}" -le 200 ]
    # no newlines
    local stripped
    stripped="$(printf '%s' "$output" | tr -d '\n')"
    [ "$output" = "$stripped" ]
}

# ---------------------------------------------------------------------------
# Appending " | attempt 1/2" keeps total ≤230 chars
# ---------------------------------------------------------------------------

@test "bounty_truncate_detail: result + ' | attempt 1/2' suffix is ≤230 chars" {
    # Build a string well over 200 chars to force truncation.
    local long_input=""
    for i in $(seq 1 10); do
        long_input="${long_input}error in pipeline stage ${i} caused by missing fixture data "
    done

    local diag
    diag="$(bounty_truncate_detail "$long_input")"
    local full_detail="${diag:+${diag} | }attempt 1/2"
    [ "${#full_detail}" -le 230 ]
}

# ---------------------------------------------------------------------------
# Whitespace is collapsed (multiple spaces/tabs become one space)
# ---------------------------------------------------------------------------

@test "bounty_truncate_detail: multiple spaces are collapsed to one" {
    local input="foo   bar    baz"
    run bounty_truncate_detail "$input"
    [ "$status" -eq 0 ]
    [ "$output" = "foo bar baz" ]
}
