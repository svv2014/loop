#!/usr/bin/env bats
# tests/backend-remove-label-multi.bats — covers backend_remove_label accepting
# multiple label args (issue #359). Previously the function silently dropped
# args after the 3rd, causing review-handler / dev-handler to fail silently
# when stripping a list of labels.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    # Source the backend function under test first, then override
    # loop_remove_label so the test can observe individual calls without
    # hitting the real gh CLI.
    source "$REPO_ROOT/lib/backends/github.sh"

    loop_remove_label() {
        echo "remove $2 $3" >> "$OPS_LOG"
    }
    export -f loop_remove_label
}

teardown() {
    rm -f "$OPS_LOG"
}

@test "backend_remove_label: single label removes one" {
    backend_remove_label "owner/repo" 100 "needs-qa"
    [ "$(wc -l < "$OPS_LOG")" -eq 1 ]
    grep -q "remove 100 needs-qa" "$OPS_LOG"
}

@test "backend_remove_label: multiple labels removes each" {
    backend_remove_label "owner/repo" 100 "needs-qa" "needs-dev" "in-review"
    [ "$(wc -l < "$OPS_LOG")" -eq 3 ]
    grep -q "remove 100 needs-qa"   "$OPS_LOG"
    grep -q "remove 100 needs-dev"  "$OPS_LOG"
    grep -q "remove 100 in-review"  "$OPS_LOG"
}

@test "backend_remove_label: empty labels in args are skipped" {
    backend_remove_label "owner/repo" 100 "needs-qa" "" "in-review"
    [ "$(wc -l < "$OPS_LOG")" -eq 2 ]
    grep -q "remove 100 needs-qa"  "$OPS_LOG"
    grep -q "remove 100 in-review" "$OPS_LOG"
    ! grep -q "remove 100 $" "$OPS_LOG"
}

@test "backend_remove_label: zero labels is a no-op" {
    backend_remove_label "owner/repo" 100
    [ ! -s "$OPS_LOG" ] || ! grep -q "remove" "$OPS_LOG"
}
