#!/usr/bin/env bats
# tests/reconciler-stage-label-sync.bats — unit tests for reconcile_stage_labels.
#
# Sources reconciler.sh in lib-only mode with stubbed backend functions and a
# fake gh binary.  Covers:
#   (a) ticket with no stage label gets one derived from trigger labels
#   (b) ticket with conflicting trigger labels gets one coherent stage label
#   (c) ticket with stage label but missing trigger label has trigger reapplied
#   (d) ticket with no trigger labels — no stage label invented

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOOP_MONITOR_URL=""
    export SLUG="test-slug"

    # Minimal project config so workflow helpers resolve correctly.
    cat > "$BATS_TMPDIR/projects.yaml" <<'YAML'
version: 1
projects:
  - slug: test-slug
    name: Test
    repo: owner/test-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/projects.yaml"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"

    # gh stub: label list returns empty list so ensure_stage_labels_exist
    # triggers gh label create; create calls succeed silently.
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Stubbed gh for stage-label tests.
if [ "${1:-}" = "label" ] && [ "${2:-}" = "list" ]; then
    # Return existing labels from GH_EXISTING_LABELS env (newline-separated).
    printf '%s\n' "${GH_EXISTING_LABELS:-}"
    exit 0
fi
if [ "${1:-}" = "label" ] && [ "${2:-}" = "create" ]; then
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
    printf '%s\n' "${MOCK_ISSUES_JSON:-[]}"
    exit 0
fi
exit 0
GHEOF
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Pretend all loop:stage:* labels already exist so create is a no-op.
    export GH_EXISTING_LABELS="loop:stage:po
loop:stage:dev
loop:stage:review
loop:stage:qa
loop:stage:merge
loop:stage:blocked
loop:stage:done"

    # Suppress LOOP_EXTRA_PATH so lib/env.sh does not prepend system bin dirs
    # (e.g. /opt/homebrew/bin) to PATH and shadow the fake gh stub.
    export LOOP_EXTRA_PATH=""

    # Source the reconciler in lib-only mode to pick up reconcile_stage_labels.
    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Re-ensure the stub bin dir is first in PATH after env.sh may have reset it.
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Override backend functions AFTER sourcing so they take precedence over
    # whatever lib/backends/backend.sh defined.
    backend_add_label()    { echo "add $2 $3"    >> "$OPS_LOG"; }
    backend_remove_label() { echo "remove $2 $3" >> "$OPS_LOG"; }
    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" "$OPS_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# (a) No stage label → derive from trigger labels and add it
# ---------------------------------------------------------------------------

@test "(a) needs-dev only: adds loop:stage:dev" {
    export MOCK_ISSUES_JSON='[{
        "number": 1,
        "labels": [{"name":"needs-dev"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 1 loop:stage:dev" "$OPS_LOG"
}

@test "(a) needs-po only: adds loop:stage:po" {
    export MOCK_ISSUES_JSON='[{
        "number": 2,
        "labels": [{"name":"needs-po"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 2 loop:stage:po" "$OPS_LOG"
}

@test "(a) needs-review only: adds loop:stage:review" {
    export MOCK_ISSUES_JSON='[{
        "number": 3,
        "labels": [{"name":"needs-review"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 3 loop:stage:review" "$OPS_LOG"
}

@test "(a) needs-qa only: adds loop:stage:qa" {
    export MOCK_ISSUES_JSON='[{
        "number": 4,
        "labels": [{"name":"needs-qa"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 4 loop:stage:qa" "$OPS_LOG"
}

@test "(a) blocked label: adds loop:stage:blocked" {
    export MOCK_ISSUES_JSON='[{
        "number": 5,
        "labels": [{"name":"blocked"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 5 loop:stage:blocked" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (b) Conflicting trigger labels → one coherent stage label derived from
#     highest-priority trigger (merge > qa > review > dev > po)
# ---------------------------------------------------------------------------

@test "(b) needs-dev + needs-review: stage=review wins (higher priority)" {
    export MOCK_ISSUES_JSON='[{
        "number": 10,
        "labels": [{"name":"needs-dev"},{"name":"needs-review"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    # Stage label should be review (higher than dev)
    grep -q "add 10 loop:stage:review" "$OPS_LOG"
}

@test "(b) needs-po + needs-dev: stage=dev wins" {
    export MOCK_ISSUES_JSON='[{
        "number": 11,
        "labels": [{"name":"needs-po"},{"name":"needs-dev"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 11 loop:stage:dev" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (c) Stage label present but trigger label missing → reapply trigger
# ---------------------------------------------------------------------------

@test "(c) loop:stage:dev set but needs-dev missing: needs-dev reapplied" {
    # Issue has stage:dev but no needs-dev trigger → stage wins, needs-dev added
    export MOCK_ISSUES_JSON='[{
        "number": 20,
        "labels": [{"name":"loop:stage:dev"},{"name":"p1-high"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    # Stage label says dev → add needs-dev trigger
    grep -q "add 20 needs-dev" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# (d) No trigger labels → no stage label invented; dangling stage label removed
# ---------------------------------------------------------------------------

@test "(d) no trigger labels, no stage label: no-op" {
    export MOCK_ISSUES_JSON='[{
        "number": 30,
        "labels": [{"name":"p0-critical"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    # Nothing should be written to the ops log for this issue
    ! grep -q " 30 " "$OPS_LOG"
}

@test "(d) no trigger labels but dangling stage label: trigger reapplied (stage wins)" {
    export MOCK_ISSUES_JSON='[{
        "number": 31,
        "labels": [{"name":"loop:stage:dev"},{"name":"p0-critical"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    grep -q "add 31 needs-dev" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Already-correct: no mutations
# ---------------------------------------------------------------------------

@test "correct stage label present: no mutation" {
    export MOCK_ISSUES_JSON='[{
        "number": 40,
        "labels": [{"name":"needs-dev"},{"name":"loop:stage:dev"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    # No add/remove for issue 40
    ! grep -q " 40 " "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# DRY_RUN: no mutations even when changes needed
# ---------------------------------------------------------------------------

@test "DRY_RUN=true: no backend mutations even when stage label missing" {
    export DRY_RUN=true
    export MOCK_ISSUES_JSON='[{
        "number": 50,
        "labels": [{"name":"needs-dev"}]
    }]'
    run reconcile_stage_labels "$REPO" "$SLUG"
    [ "$status" -eq 0 ]
    # Ops log should not contain any add/remove for issue 50.
    ! grep -q " 50 " "$OPS_LOG"
}
