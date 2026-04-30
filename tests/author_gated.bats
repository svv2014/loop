#!/usr/bin/env bats
# tests/author_gated.bats — unit tests for lib/author_gate.sh
#
# Stubs gh as a shell function so no real GitHub calls are made. Covers:
#   - dedup per (slug, number) when an entry surfaces in both queries
#   - counter file written for `loop status` consumption
#   - operator-approved label bypasses the gate
#   - empty ALLOWED_AUTHORS short-circuits to count=0
#   - allow-listed authors are excluded
#   - author_gate_pending_total sums per-slug counters

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    export LOOP_AUTHOR_GATED_DIR="$BATS_TMPDIR/author-gated"
    mkdir -p "$LOOP_LOG_DIR" "$LOOP_AUTHOR_GATED_DIR"

    export LOG_LINES="$BATS_TMPDIR/log.out"
    : > "$LOG_LINES"

    # Capture log output for assertions.
    log() { printf '%s\n' "$*" >> "$LOG_LINES"; }
    export -f log

    # gh stub: returns canned JSON keyed off the subcommand.
    # GH_ISSUES_JSON / GH_PRS_JSON drive the responses.
    gh() {
        case "$1" in
            issue) printf '%s' "${GH_ISSUES_JSON:-[]}" ;;
            pr)    printf '%s' "${GH_PRS_JSON:-[]}"    ;;
            *)     return 0 ;;
        esac
    }
    export -f gh

    # shellcheck source=../lib/author_gate.sh
    source "$REPO_ROOT/lib/author_gate.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/author-gated" \
           "$BATS_TMPDIR/log.out" 2>/dev/null || true
    unset -f log gh 2>/dev/null || true
}

@test "reconcile_author_gated: emits one line per gated ticket and writes count" {
    export ALLOWED_AUTHORS="alice,bob"
    export GH_ISSUES_JSON='[
        {"number": 10, "title": "Outsider issue", "labels": [],
         "author": {"login": "mallory"}, "createdAt": "2026-04-29T00:00:00Z"},
        {"number": 11, "title": "Bob issue",     "labels": [],
         "author": {"login": "bob"},     "createdAt": "2026-04-29T00:00:00Z"}
    ]'
    export GH_PRS_JSON='[
        {"number": 20, "title": "Outsider PR",   "labels": [],
         "author": {"login": "eve"},     "createdAt": "2026-04-29T00:00:00Z"}
    ]'

    run reconcile_author_gated "alpha" "owner/alpha"
    [ "$status" -eq 0 ]

    grep -q "author_gated: slug=alpha num=10 author=mallory" "$LOG_LINES"
    grep -q "author_gated: slug=alpha num=20 author=eve"     "$LOG_LINES"
    ! grep -q "author_gated: .* num=11 "                     "$LOG_LINES"

    [ "$(cat "$LOOP_AUTHOR_GATED_DIR/alpha.count")" = "2" ]
}

@test "reconcile_author_gated: dedups (slug, number) across issues + PRs" {
    export ALLOWED_AUTHORS="alice"
    # Same number 42 appears in both queries (impossible on GH, but we still
    # protect the digest from double-emitting on edge-case backends).
    export GH_ISSUES_JSON='[
        {"number": 42, "title": "dup", "labels": [],
         "author": {"login": "mallory"}, "createdAt": "2026-04-29T00:00:00Z"}
    ]'
    export GH_PRS_JSON='[
        {"number": 42, "title": "dup", "labels": [],
         "author": {"login": "mallory"}, "createdAt": "2026-04-29T00:00:00Z"}
    ]'

    run reconcile_author_gated "beta" "owner/beta"
    [ "$status" -eq 0 ]

    [ "$(grep -c "num=42" "$LOG_LINES")" = "1" ]
    [ "$(cat "$LOOP_AUTHOR_GATED_DIR/beta.count")" = "1" ]
}

@test "reconcile_author_gated: operator-approved label bypasses the gate" {
    export ALLOWED_AUTHORS="alice"
    export GH_ISSUES_JSON='[
        {"number": 5, "title": "approved",
         "labels": [{"name":"operator-approved"}],
         "author": {"login": "mallory"}, "createdAt": "2026-04-29T00:00:00Z"}
    ]'
    export GH_PRS_JSON='[]'

    run reconcile_author_gated "alpha" "owner/alpha"
    [ "$status" -eq 0 ]

    ! grep -q "num=5" "$LOG_LINES"
    [ "$(cat "$LOOP_AUTHOR_GATED_DIR/alpha.count")" = "0" ]
}

@test "reconcile_author_gated: empty ALLOWED_AUTHORS short-circuits to count=0" {
    export ALLOWED_AUTHORS=""
    export GH_ISSUES_JSON='[
        {"number": 9, "title": "anything",
         "labels": [], "author": {"login": "mallory"},
         "createdAt": "2026-04-29T00:00:00Z"}
    ]'
    export GH_PRS_JSON='[]'

    run reconcile_author_gated "alpha" "owner/alpha"
    [ "$status" -eq 0 ]

    ! grep -q "author_gated:" "$LOG_LINES"
    [ "$(cat "$LOOP_AUTHOR_GATED_DIR/alpha.count")" = "0" ]
}

@test "author_gate_pending_total: sums per-slug counters" {
    echo 3 > "$LOOP_AUTHOR_GATED_DIR/alpha.count"
    echo 5 > "$LOOP_AUTHOR_GATED_DIR/beta.count"
    echo 0 > "$LOOP_AUTHOR_GATED_DIR/gamma.count"

    run author_gate_pending_total
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "author_gate_pending_total: missing dir returns 0" {
    rm -rf "$LOOP_AUTHOR_GATED_DIR"
    run author_gate_pending_total
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
