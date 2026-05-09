#!/usr/bin/env bats
# tests/po-belt-and-braces.bats — unit tests for po-handler belt-and-braces guard.
#
# Verifies that the guard after a successful PO run does not double-label an
# issue that already carries a canonical dev-queue label (needs-dev, dev, etc.)
# and that the fallback label respects per-project overrides via loop_label_for.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: test-proj
    name: Test Project
    repo: owner/test-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
}

teardown() {
    rm -f "$BATS_TMPDIR/fixture.yaml" "$BATS_TMPDIR/ops.log"
}

# Inline the guard logic from po-handler.sh so the test does not need to
# source the full handler (which pulls in env/backends/runner).
_run_guard() {
    local present_labels="$1"   # space-separated labels already on the issue
    local ops_log="$2"
    local slug="${3:-test-proj}"

    backend_issue_has_any_label() {
        # $1=repo $2=num, remaining = labels to check
        shift 2
        for lbl in "$@"; do
            # shellcheck disable=SC2076
            if [[ " $present_labels " =~ " $lbl " ]]; then
                return 0
            fi
        done
        return 1
    }

    backend_add_label() {
        echo "add $3" >> "$ops_log"
    }

    log() { :; }

    # Replicate the guard block from po-handler.sh
    if ! backend_issue_has_any_label "owner/test-repo" "42" dev needs-dev needs-clarification blocked tracker 'done'; then
        _fallback_dev_label=$(loop_label_for "$slug" "dev")
        log "WARN fallback"
        backend_add_label "owner/test-repo" "42" "$_fallback_dev_label"
    fi
}

# ---------------------------------------------------------------------------

@test "guard does NOT add dev when needs-dev already present (canonical-vocab project)" {
    ops_log="$BATS_TMPDIR/ops.log"
    rm -f "$ops_log"

    _run_guard "needs-dev" "$ops_log"

    # No label should have been added
    [ ! -f "$ops_log" ] || [ "$(wc -l < "$ops_log")" -eq 0 ]
}

@test "guard does NOT add dev when legacy dev already present" {
    ops_log="$BATS_TMPDIR/ops.log"
    rm -f "$ops_log"

    _run_guard "dev" "$ops_log"

    [ ! -f "$ops_log" ] || [ "$(wc -l < "$ops_log")" -eq 0 ]
}

@test "guard does NOT add dev when needs-clarification already present" {
    ops_log="$BATS_TMPDIR/ops.log"
    rm -f "$ops_log"

    _run_guard "needs-clarification" "$ops_log"

    [ ! -f "$ops_log" ] || [ "$(wc -l < "$ops_log")" -eq 0 ]
}

@test "guard DOES add fallback dev-queue label when no progression label present" {
    ops_log="$BATS_TMPDIR/ops.log"
    rm -f "$ops_log"

    _run_guard "in-progress" "$ops_log"

    grep -q "^add " "$ops_log"
}

@test "fallback label respects loop_label_for override (canonical project returns needs-dev)" {
    ops_log="$BATS_TMPDIR/ops.log"
    rm -f "$ops_log"

    # Override loop_label_for to simulate a canonical-vocab project
    loop_label_for() { echo "needs-dev"; }

    _run_guard "in-progress" "$ops_log"

    grep -q "^add needs-dev$" "$ops_log"
}
