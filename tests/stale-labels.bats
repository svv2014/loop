#!/usr/bin/env bats
# tests/stale-labels.bats — stale pipeline-label cleanup (issue #166).
#
# Covers:
#   - merge-handler cleanup: every stage label stripped from PR + linked issue
#   - reconciler closed-issue cleanup: stage labels stripped, orthogonal kept
#   - backfill idempotency: second run produces zero strip operations

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    backend_remove_label() { echo "remove_label $2 $3" >> "$OPS_LOG"; }
    backend_add_label()    { echo "add_label $2 $3"    >> "$OPS_LOG"; }
    backend_close_issue()  { echo "close_issue $2"     >> "$OPS_LOG"; }

    # shellcheck source=../lib/labels.sh
    source "$REPO_ROOT/lib/labels.sh"
}

teardown() {
    rm -f "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# loop_strip_pipeline_labels: scoped strip honours intersection
# ---------------------------------------------------------------------------

@test "loop_strip_pipeline_labels strips only stage labels in the existing CSV" {
    # Issue carries: needs-qa (stage), qa-pass (stage), p1 (orthogonal),
    # semver:minor (orthogonal). Only the stage labels should be stripped.
    run loop_strip_pipeline_labels "owner/repo" "42" "needs-qa,qa-pass,p1,semver:minor"
    [ "$status" -eq 0 ]
    grep -qx "remove_label 42 needs-qa" "$OPS_LOG"
    grep -qx "remove_label 42 qa-pass"  "$OPS_LOG"
    ! grep -q  "remove_label 42 p1"           "$OPS_LOG"
    ! grep -q  "remove_label 42 semver:minor" "$OPS_LOG"
}

@test "loop_strip_pipeline_labels with empty existing tries every stage label" {
    run loop_strip_pipeline_labels "owner/repo" "1" ""
    [ "$status" -eq 0 ]
    # Should attempt every entry in LOOP_PIPELINE_STAGE_LABELS
    local lbl
    for lbl in "${LOOP_PIPELINE_STAGE_LABELS[@]}"; do
        grep -qx "remove_label 1 ${lbl}" "$OPS_LOG"
    done
}

# ---------------------------------------------------------------------------
# Merge-handler cleanup path: simulate the post-merge label sequence
# ---------------------------------------------------------------------------

@test "merge-handler post-merge sequence: PR + linked issue have all stage labels stripped, done is added on issue" {
    # PR #100 had: needs-qa, qa-pass, semver:patch (orthogonal preserved).
    # Linked issue #50 had: needs-clarification, p1 (orthogonal preserved).
    loop_strip_pipeline_labels "owner/repo" "100" "needs-qa,qa-pass,semver:patch" >/dev/null
    loop_strip_pipeline_labels "owner/repo" "50"  "needs-clarification,p1"        >/dev/null
    backend_add_label    "owner/repo" "50" "done"
    backend_close_issue  "owner/repo" "50"

    # PR side
    grep -qx "remove_label 100 needs-qa" "$OPS_LOG"
    grep -qx "remove_label 100 qa-pass"  "$OPS_LOG"
    ! grep -q "remove_label 100 semver:patch" "$OPS_LOG"

    # Issue side
    grep -qx "remove_label 50 needs-clarification" "$OPS_LOG"
    grep -qx "add_label 50 done"   "$OPS_LOG"
    grep -qx "close_issue 50"      "$OPS_LOG"
    ! grep -q "remove_label 50 p1" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Reconciler closed-issue path
# ---------------------------------------------------------------------------

@test "reconciler closed-issue cleanup strips stage labels and preserves orthogonal" {
    # Closed issue carrying both stage and orthogonal labels.
    loop_strip_pipeline_labels "owner/repo" "141" "needs-clarification,p1-high" >/dev/null

    grep -qx "remove_label 141 needs-clarification" "$OPS_LOG"
    ! grep -q "remove_label 141 p1-high" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Backfill idempotency: simulate "first run strips, second run sees clean"
# ---------------------------------------------------------------------------

@test "backfill is idempotent — second pass over already-clean tickets emits no strip ops" {
    # First pass: ticket has stage label "needs-review" + orthogonal "p2".
    # The strip is recorded, then we simulate the resulting clean state.
    loop_strip_pipeline_labels "owner/repo" "200" "needs-review,p2" >/dev/null
    grep -qx "remove_label 200 needs-review" "$OPS_LOG"

    # Reset ops log to capture second-pass behavior only.
    rm -f "$OPS_LOG"; touch "$OPS_LOG"

    # Second pass: ticket is now clean — only orthogonal labels remain.
    # The intersection is empty, so loop_strip_pipeline_labels must be a no-op
    # for a ticket whose existing labels contain no stage members.
    # Simulate by passing only orthogonal labels in the existing CSV.
    loop_strip_pipeline_labels "owner/repo" "200" "p2" >/dev/null

    # No remove_label ops at all on the second pass.
    [ ! -s "$OPS_LOG" ] || {
        echo "expected empty ops log, got:"; cat "$OPS_LOG"; false
    }
}
