#!/usr/bin/env bats
# tests/workflow.bats — unit tests for loop_workflow_validate in lib/workflow.sh.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"
    # Temp dir for test fixture files
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Write a minimal valid workflow YAML for a given name.
write_valid_workflow() {
    local name="$1"
    cat > "$TEST_TMP/${name}.yaml" <<YAML
version: 1
name: ${name}
description: test workflow

issue_stages:
  - id: plan
    trigger_label: plan
    handler: dev-handler
    on_done: done
YAML
}

# ---------------------------------------------------------------------------
# Valid file passes
# ---------------------------------------------------------------------------

@test "validate: valid minimal workflow passes" {
    write_valid_workflow "test-wf"
    run loop_workflow_validate "$TEST_TMP/test-wf.yaml"
    [ "$status" -eq 0 ]
}

@test "validate: all committed starter workflows pass validation" {
    run loop_workflow_validate "$REPO_ROOT/config/workflows/default.yaml"
    [ "$status" -eq 0 ]
    run loop_workflow_validate "$REPO_ROOT/config/workflows/minimal.yaml"
    [ "$status" -eq 0 ]
    run loop_workflow_validate "$REPO_ROOT/config/workflows/docs-only.yaml"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Missing version fails
# ---------------------------------------------------------------------------

@test "validate: missing version field fails" {
    cat > "$TEST_TMP/no-version.yaml" <<YAML
name: no-version
issue_stages:
  - id: plan
    trigger_label: plan
    handler: dev-handler
YAML
    run loop_workflow_validate "$TEST_TMP/no-version.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"version"* ]]
}

@test "validate: version=2 fails" {
    cat > "$TEST_TMP/v2.yaml" <<YAML
version: 2
name: v2
issue_stages:
  - id: plan
    trigger_label: plan
    handler: dev-handler
YAML
    run loop_workflow_validate "$TEST_TMP/v2.yaml"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# name must match filename
# ---------------------------------------------------------------------------

@test "validate: name mismatch with filename fails" {
    cat > "$TEST_TMP/mywf.yaml" <<YAML
version: 1
name: otherwf
issue_stages:
  - id: plan
    trigger_label: plan
    handler: dev-handler
YAML
    run loop_workflow_validate "$TEST_TMP/mywf.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"name"* ]]
}

# ---------------------------------------------------------------------------
# Duplicate trigger_label fails
# ---------------------------------------------------------------------------

@test "validate: duplicate trigger_label within issue_stages fails" {
    cat > "$TEST_TMP/dup.yaml" <<YAML
version: 1
name: dup
issue_stages:
  - id: stage1
    trigger_label: plan
    handler: dev-handler
    on_done: done
  - id: stage2
    trigger_label: plan
    handler: dev-handler
    on_done: done
YAML
    run loop_workflow_validate "$TEST_TMP/dup.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate"* ]]
}

@test "validate: same trigger_label across issue_stages and pr_stages is allowed" {
    # Issues and PRs are distinct objects; one canonical label (e.g.
    # `needs-dev`) may legitimately trigger both an issue stage and a
    # PR-rework stage. The duplicate-trigger check is therefore scoped to
    # a single section. See config/workflows/default.yaml and docs-only.yaml.
    cat > "$TEST_TMP/xdup.yaml" <<YAML
version: 1
name: xdup
issue_stages:
  - id: plan
    trigger_label: shared-label
    handler: dev-handler
    on_done: done
pr_stages:
  - id: merge
    trigger_label: shared-label
    handler: merge-handler
    on_done: done
YAML
    run loop_workflow_validate "$TEST_TMP/xdup.yaml"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Unknown transition target fails
# ---------------------------------------------------------------------------

@test "validate: unknown transition target fails" {
    cat > "$TEST_TMP/badtrans.yaml" <<YAML
version: 1
name: badtrans
issue_stages:
  - id: plan
    trigger_label: plan
    handler: dev-handler
    on_done: nonexistent-label
YAML
    run loop_workflow_validate "$TEST_TMP/badtrans.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nonexistent-label"* ]]
}

@test "validate: transition to terminal label 'done' passes" {
    cat > "$TEST_TMP/term.yaml" <<YAML
version: 1
name: term
issue_stages:
  - id: plan
    trigger_label: plan
    handler: dev-handler
    on_done: done
    on_failed_after_max: blocked
YAML
    run loop_workflow_validate "$TEST_TMP/term.yaml"
    [ "$status" -eq 0 ]
}

@test "validate: decisions approve/reject referencing unknown labels fails" {
    cat > "$TEST_TMP/baddec.yaml" <<YAML
version: 1
name: baddec
pr_stages:
  - id: review
    trigger_label: needs-review
    handler: review-handler
    decisions:
      approve: unknown-target
      reject: needs-rework
YAML
    run loop_workflow_validate "$TEST_TMP/baddec.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown-target"* ]]
}

# ---------------------------------------------------------------------------
# Zero stages fails
# ---------------------------------------------------------------------------

@test "validate: empty workflow with no stages fails" {
    cat > "$TEST_TMP/empty.yaml" <<YAML
version: 1
name: empty
YAML
    run loop_workflow_validate "$TEST_TMP/empty.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zero stages"* ]]
}

# ---------------------------------------------------------------------------
# Missing required stage fields fail
# ---------------------------------------------------------------------------

@test "validate: stage missing trigger_label fails" {
    cat > "$TEST_TMP/notrig.yaml" <<YAML
version: 1
name: notrig
issue_stages:
  - id: plan
    handler: dev-handler
    on_done: done
YAML
    run loop_workflow_validate "$TEST_TMP/notrig.yaml"
    [ "$status" -ne 0 ]
}

@test "validate: stage missing handler fails" {
    cat > "$TEST_TMP/nohandler.yaml" <<YAML
version: 1
name: nohandler
issue_stages:
  - id: plan
    trigger_label: plan
    on_done: done
YAML
    run loop_workflow_validate "$TEST_TMP/nohandler.yaml"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Missing handler script warns but does not fail
# ---------------------------------------------------------------------------

@test "validate: missing handler script produces warning but passes" {
    cat > "$TEST_TMP/missinghandler.yaml" <<YAML
version: 1
name: missinghandler
issue_stages:
  - id: plan
    trigger_label: plan
    handler: nonexistent-handler-xyz
    on_done: done
YAML
    run loop_workflow_validate "$TEST_TMP/missinghandler.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}
