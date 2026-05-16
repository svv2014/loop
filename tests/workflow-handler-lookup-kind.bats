#!/usr/bin/env bats
# tests/workflow-handler-lookup-kind.bats —
# Regression coverage for issue #441: when a label triggers both an
# issue_stage and a pr_stage, loop_handler_for_label must disambiguate
# by kind. Previously returned the first match across both sections,
# making the PR rework handler unreachable in the default workflow.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

    TEST_TMP="$(mktemp -d)"
    cat > "$TEST_TMP/dual.yaml" <<'YAML'
version: 1
name: dual
description: shared-label test workflow
issue_stages:
  - id: dev
    trigger_label: shared-label
    handler: dev-handler
    on_done: review-pending
pr_stages:
  - id: rework
    trigger_label: shared-label
    handler: dev-rework-handler
    on_done: review-pending
YAML
    # Override workflow dir + slug-to-workflow mapping for the test.
    _LOOP_WORKFLOW_DIR="$TEST_TMP"
    loop_workflow_for_project() { echo "dual"; }
    export LOOP_CONFIG="$TEST_TMP/projects.yaml"
    : > "$LOOP_CONFIG"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "handler-lookup: kind=issue returns issue-stage handler for shared label" {
    run loop_handler_for_label dummy shared-label issue
    [ "$status" -eq 0 ]
    [ "$output" = "dev-handler" ]
}

@test "handler-lookup: kind=pr returns pr-stage handler for shared label (the #441 fix)" {
    run loop_handler_for_label dummy shared-label pr
    [ "$status" -eq 0 ]
    [ "$output" = "dev-rework-handler" ]
}

@test "handler-lookup: no kind preserves legacy behaviour (first match wins)" {
    run loop_handler_for_label dummy shared-label
    [ "$status" -eq 0 ]
    [ "$output" = "dev-handler" ]
}

@test "handler-lookup: kind=pr returns nothing when label only in issue_stages" {
    cat > "$TEST_TMP/issue-only.yaml" <<'YAML'
version: 1
name: issue-only
description: issue-only stages
issue_stages:
  - id: dev
    trigger_label: only-issue
    handler: dev-handler
    on_done: done
YAML
    loop_workflow_for_project() { echo "issue-only"; }
    run loop_handler_for_label dummy only-issue pr
    [ "$status" -ne 0 ]
}

@test "handler-lookup: default workflow resolves loop:action:dev to dev-rework-handler when kind=pr" {
    _LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"
    loop_workflow_for_project() { echo "default"; }
    run loop_handler_for_label loop "loop:action:dev" pr
    [ "$status" -eq 0 ]
    [ "$output" = "dev-rework-handler" ]
}
