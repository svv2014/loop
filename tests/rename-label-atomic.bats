#!/usr/bin/env bats
# tests/rename-label-atomic.bats — coverage for _rename_label_on_target.
#
# Verifies the post-#198 contract: add-then-remove ordering, with the
# original label preserved on add-failure. Catches the loop-monitor
# PR #95/#88/#75 empty-label regression.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOOP_RECONCILER_LIB_ONLY=1

    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Stubs override real backend after sourcing.
    # Default: success. Tests can override per-case via $ADD_FAILS / $REMOVE_FAILS.
    backend_add_label() {
        echo "ADD $*" >> "$OPS_LOG"
        if [ -n "${ADD_FAILS:-}" ] && [ "$3" = "$ADD_FAILS" ]; then
            return 1
        fi
        return 0
    }
    backend_remove_label() {
        echo "REMOVE $*" >> "$OPS_LOG"
        if [ -n "${REMOVE_FAILS:-}" ] && [ "$3" = "$REMOVE_FAILS" ]; then
            return 1
        fi
        return 0
    }
}

teardown() {
    rm -f "$OPS_LOG"
    unset ADD_FAILS REMOVE_FAILS
}

@test "happy path: add canonical first, then remove alias (order matters)" {
    run _rename_label_on_target "$REPO" 42 issue po-review needs-po
    [ "$status" -eq 0 ]

    # ADD must come before REMOVE in the ops log.
    grep -n "^ADD .* needs-po"     "$OPS_LOG"
    grep -n "^REMOVE .* po-review" "$OPS_LOG"
    local add_line remove_line
    add_line=$(grep -n "^ADD .* needs-po"     "$OPS_LOG" | head -1 | cut -d: -f1)
    remove_line=$(grep -n "^REMOVE .* po-review" "$OPS_LOG" | head -1 | cut -d: -f1)
    [ "$add_line" -lt "$remove_line" ]
}

@test "add failure: keeps the original label, does NOT call remove (regression guard)" {
    ADD_FAILS=needs-po

    run _rename_label_on_target "$REPO" 42 issue po-review needs-po
    [ "$status" -eq 1 ]   # function reports failure

    # ADD was attempted (and failed); REMOVE must NOT be called — otherwise
    # the ticket would end up label-less.
    grep -q "^ADD .* needs-po"        "$OPS_LOG"
    ! grep -q "^REMOVE .* po-review"  "$OPS_LOG"
}

@test "remove failure: warns but doesn't error — both labels present (idempotent)" {
    REMOVE_FAILS=po-review

    run _rename_label_on_target "$REPO" 42 issue po-review needs-po
    [ "$status" -eq 0 ]   # rename considered successful even with cleanup blip

    # ADD succeeded; REMOVE attempted but failed — that's recoverable.
    grep -q "^ADD .* needs-po"      "$OPS_LOG"
    grep -q "^REMOVE .* po-review"  "$OPS_LOG"
}

@test "DRY_RUN=true: zero backend calls" {
    DRY_RUN=true
    run _rename_label_on_target "$REPO" 42 issue po-review needs-po
    [ "$status" -eq 0 ]
    [ ! -s "$OPS_LOG" ]
    DRY_RUN=false
}
