#!/usr/bin/env bats
# tests/pr-watchdog.bats — unit tests for pr-watchdog rework label resolution.
#
# Verifies that loop_stage_trigger drives $rework_label, with correct fallback.

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
    rm -f "$BATS_TMPDIR/fixture.yaml"
}

# ---------------------------------------------------------------------------
# rework_label resolution
# ---------------------------------------------------------------------------

@test "rework_label: default workflow resolves to needs-dev via loop_stage_trigger" {
    # Run the resolution snippet from pr-watchdog.sh in a subshell
    result=$(
        rework_label=$(loop_stage_trigger "test-proj" "rework" "pr" 2>/dev/null || echo "")
        [ -z "$rework_label" ] && rework_label="needs-rework"
        echo "$rework_label"
    )
    [ "$result" = "needs-dev" ]
}

@test "rework_label: falls back to needs-rework when loop_stage_trigger returns non-zero" {
    # Override loop_stage_trigger to simulate a missing workflow
    loop_stage_trigger() { return 1; }
    export -f loop_stage_trigger

    result=$(
        rework_label=$(loop_stage_trigger "no-wf-proj" "rework" "pr" 2>/dev/null || echo "")
        [ -z "$rework_label" ] && rework_label="needs-rework"
        echo "$rework_label"
    )
    [ "$result" = "needs-rework" ]
}

@test "rework_label: falls back to needs-rework when loop_stage_trigger outputs empty string" {
    # Override loop_stage_trigger to echo nothing (empty stdout, exit 0)
    loop_stage_trigger() { echo ""; return 0; }
    export -f loop_stage_trigger

    result=$(
        rework_label=$(loop_stage_trigger "no-wf-proj" "rework" "pr" 2>/dev/null || echo "")
        [ -z "$rework_label" ] && rework_label="needs-rework"
        echo "$rework_label"
    )
    [ "$result" = "needs-rework" ]
}
