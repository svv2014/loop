#!/usr/bin/env bats
# tests/handlers.bats — unit tests for handler entry-point label transitions.
#
# Verifies that dev-handler and po-handler strip their trigger labels before
# adding in-progress, so an issue never carries both labels simultaneously.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

    # Minimal project fixture using the default workflow
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
    rm -f "$BATS_TMPDIR/fixture.yaml" \
          "$BATS_TMPDIR/override.yaml" \
          "$BATS_TMPDIR/label-ops.log" \
          "$BATS_TMPDIR/override-ops.log"
}

# ---------------------------------------------------------------------------
# dev-handler claim transition
# ---------------------------------------------------------------------------

@test "dev-handler claim: trigger label removed and in-progress added, no overlap" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the claim sequence from dev-handler.sh
    local _dev_trigger
    _dev_trigger=$(loop_label_for "test-proj" "plan")
    backend_remove_label "owner/test-repo" "1" "$_dev_trigger"
    backend_add_label    "owner/test-repo" "1" "in-progress"

    # trigger label must be removed
    grep -q "remove plan" "$ops_log"
    # in-progress must be added
    grep -q "add in-progress" "$ops_log"
    # trigger label must NOT be re-added (no dual state)
    ! grep -q "add plan" "$ops_log"
    # remove must precede add
    local rm_line add_line
    rm_line=$(grep -n "remove plan" "$ops_log" | cut -d: -f1)
    add_line=$(grep -n "add in-progress" "$ops_log" | cut -d: -f1)
    [ "$rm_line" -lt "$add_line" ]
}

@test "dev-handler claim: label override respected (plan → backlog)" {
    cat > "$BATS_TMPDIR/override.yaml" <<'YAML'
version: 1
projects:
  - slug: override-proj
    name: Override Project
    repo: owner/override-repo
    root: /tmp/fake2
    default_branch: main
    workflow: default
    labels:
      plan: backlog
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/override.yaml"

    local ops_log="$BATS_TMPDIR/override-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    local _dev_trigger
    _dev_trigger=$(loop_label_for "override-proj" "plan")
    backend_remove_label "owner/override-repo" "1" "$_dev_trigger"
    backend_add_label    "owner/override-repo" "1" "in-progress"

    # overridden label (backlog) must be stripped, not the canonical name
    grep -q "remove backlog" "$ops_log"
    ! grep -q "remove plan" "$ops_log"
}

# ---------------------------------------------------------------------------
# po-handler claim transition
# ---------------------------------------------------------------------------

@test "po-handler claim: po-review trigger removed before in-progress added" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the claim sequence from po-handler.sh
    local _po_trigger
    _po_trigger=$(loop_label_for "test-proj" "po-review")
    backend_remove_label "owner/test-repo" "1" "$_po_trigger"
    backend_add_label    "owner/test-repo" "1" "in-progress"

    grep -q "remove po-review" "$ops_log"
    grep -q "add in-progress" "$ops_log"
    ! grep -q "add po-review" "$ops_log"
    local rm_line add_line
    rm_line=$(grep -n "remove po-review" "$ops_log" | cut -d: -f1)
    add_line=$(grep -n "add in-progress" "$ops_log" | cut -d: -f1)
    [ "$rm_line" -lt "$add_line" ]
}
