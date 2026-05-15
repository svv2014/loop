#!/usr/bin/env bats
# tests/loop_cli_priority.bats — tests for bin/loop priority subcommands.
#
# Mocks 'gh' as a shell function that:
#   - Records arguments to $GH_CALLS_FILE
#   - For 'gh issue view ... --json labels', returns canned JSON

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CLI="$REPO_ROOT/bin/loop"

setup() {
    export GH_CALLS_FILE="$BATS_TMPDIR/gh_calls_$$.txt"
    # Canned label name output (one name per line, as jq '.labels[].name' would produce)
    # p2-medium present
    export GH_LABELS_JSON=$'p2-medium\nbug'
    # No priority label
    export GH_LABELS_NONE_JSON='bug'
    # p0 present
    export GH_LABELS_P0_JSON='p0-critical'
    # p3 present
    export GH_LABELS_P3_JSON='p3-low'

    > "$GH_CALLS_FILE"

    # Mock gh as a script available to the CLI via PATH
    export GH_MOCK_DIR="$BATS_TMPDIR/mock_bin_$$"
    mkdir -p "$GH_MOCK_DIR"

    # Default mock: p2-medium present
    export GH_LABELS_RESPONSE="$GH_LABELS_JSON"

    cat > "$GH_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALLS_FILE"
# Detect 'gh issue view ... --json labels' and return canned label names (one per line)
found_view=false
found_json=false
for arg in "$@"; do
    [ "$arg" = "view" ]   && found_view=true
    [ "$arg" = "--json" ] && found_json=true
done
if $found_view && $found_json; then
    printf '%s\n' $GH_LABELS_RESPONSE
    exit 0
fi
exit 0
MOCK
    chmod +x "$GH_MOCK_DIR/gh"
    export PATH="$GH_MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$GH_CALLS_FILE" "$GH_MOCK_DIR"
    unset GH_CALLS_FILE GH_LABELS_JSON GH_LABELS_NONE_JSON GH_LABELS_P0_JSON \
          GH_LABELS_P3_JSON GH_MOCK_DIR GH_LABELS_RESPONSE
}

# ─────────────────────────────────────────────────────────────────────────────
# --help / bare priority
# ─────────────────────────────────────────────────────────────────────────────

@test "loop priority --help exits 0 and prints usage" {
    run "$CLI" priority --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"set"* ]]
    [[ "$output" == *"bump"* ]]
    [[ "$output" == *"drop"* ]]
}

@test "bare 'loop priority' exits 0 and prints usage" {
    run "$CLI" priority
    [ "$status" -eq 0 ]
    [[ "$output" == *"set"* ]]
    [[ "$output" == *"bump"* ]]
    [[ "$output" == *"drop"* ]]
}

@test "bare 'loop' exits 0 and prints commands" {
    run "$CLI"
    [ "$status" -eq 0 ]
    [[ "$output" == *"priority"* ]]
}

@test "loop --help exits 0" {
    run "$CLI" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"priority"* ]]
}

@test "loop unknown-command exits non-zero" {
    run "$CLI" unknown-command
    [ "$status" -ne 0 ]
}

@test "loop priority unknown-subcmd exits non-zero" {
    run "$CLI" priority frobnicate
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# priority set
# ─────────────────────────────────────────────────────────────────────────────

@test "priority set calls gh issue edit with --add-label and --remove-label" {
    export GH_LABELS_RESPONSE="$GH_LABELS_JSON"   # current: p2-medium
    run "$CLI" priority set owner/repo 42 p0
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"--add-label"* ]]
    [[ "$calls" == *"p0-critical"* ]]
    [[ "$calls" == *"--remove-label"* ]]
    [[ "$calls" == *"p2-medium"* ]]
}

@test "priority set p1 adds p1-high" {
    export GH_LABELS_RESPONSE="$GH_LABELS_NONE_JSON"   # no priority label
    run "$CLI" priority set owner/repo 10 p1
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p1-high"* ]]
}

@test "priority set p2 adds p2-medium" {
    export GH_LABELS_RESPONSE="$GH_LABELS_NONE_JSON"
    run "$CLI" priority set owner/repo 10 p2
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p2-medium"* ]]
}

@test "priority set p3 adds p3-low" {
    export GH_LABELS_RESPONSE="$GH_LABELS_NONE_JSON"
    run "$CLI" priority set owner/repo 10 p3
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p3-low"* ]]
}

@test "priority set unknown tier exits non-zero" {
    run "$CLI" priority set owner/repo 10 p9
    [ "$status" -ne 0 ]
}

@test "priority set with missing args exits non-zero" {
    run "$CLI" priority set owner/repo 10
    [ "$status" -ne 0 ]
}

@test "priority set with no args exits non-zero" {
    run "$CLI" priority set
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# priority bump
# ─────────────────────────────────────────────────────────────────────────────

@test "priority bump from p2 adds p1-high and removes p2-medium" {
    export GH_LABELS_RESPONSE="$GH_LABELS_JSON"   # current: p2-medium
    run "$CLI" priority bump owner/repo 42
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p1-high"* ]]
    [[ "$calls" == *"--remove-label"* ]]
    [[ "$calls" == *"p2-medium"* ]]
}

@test "priority bump from p0 is a no-op (exit 0, message to stderr)" {
    export GH_LABELS_RESPONSE="$GH_LABELS_P0_JSON"   # current: p0-critical
    run "$CLI" priority bump owner/repo 42
    [ "$status" -eq 0 ]
    # No edit call should be made
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" != *"issue edit"* ]]
}

@test "priority bump with no priority label sets p3-low" {
    export GH_LABELS_RESPONSE="$GH_LABELS_NONE_JSON"
    run "$CLI" priority bump owner/repo 42
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p3-low"* ]]
}

@test "priority bump with missing args exits non-zero" {
    run "$CLI" priority bump owner/repo
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# priority drop
# ─────────────────────────────────────────────────────────────────────────────

@test "priority drop from p2 adds p3-low and removes p2-medium" {
    export GH_LABELS_RESPONSE="$GH_LABELS_JSON"   # current: p2-medium
    run "$CLI" priority drop owner/repo 42
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p3-low"* ]]
    [[ "$calls" == *"--remove-label"* ]]
    [[ "$calls" == *"p2-medium"* ]]
}

@test "priority drop from p3 is a no-op (exit 0, message to stderr)" {
    export GH_LABELS_RESPONSE="$GH_LABELS_P3_JSON"   # current: p3-low
    run "$CLI" priority drop owner/repo 42
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" != *"issue edit"* ]]
}

@test "priority drop with no priority label is a no-op (exit 0)" {
    export GH_LABELS_RESPONSE="$GH_LABELS_NONE_JSON"
    run "$CLI" priority drop owner/repo 42
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" != *"issue edit"* ]]
}

@test "priority drop from p0 adds p1-high and removes p0-critical" {
    export GH_LABELS_RESPONSE="$GH_LABELS_P0_JSON"
    run "$CLI" priority drop owner/repo 42
    [ "$status" -eq 0 ]
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *"p1-high"* ]]
    [[ "$calls" == *"--remove-label"* ]]
    [[ "$calls" == *"p0-critical"* ]]
}

@test "priority drop with missing args exits non-zero" {
    run "$CLI" priority drop owner/repo
    [ "$status" -ne 0 ]
}
