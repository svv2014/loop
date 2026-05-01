#!/usr/bin/env bats
# tests/label-is-trigger.bats — coverage for loop_label_is_trigger.
#
# Verifies the shared workflow-aware gate (extracted from duplicate copies
# in reconcile_synonym_labels and reconcile_alias_renames per #209).
#
# Self-contained: synthesizes a temp workflow dir with two workflow YAMLs
# so the test doesn't depend on the in-tree config/workflows/ files (some
# of which are gitignored for local-only operator config).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    # Synthetic workflow dir with two distinct workflows.
    export LOOP_WORKFLOW_DIR="$BATS_TMPDIR/wf-$$"
    mkdir -p "$LOOP_WORKFLOW_DIR"

    cat > "$LOOP_WORKFLOW_DIR/canon.yaml" <<'YAML'
version: 1
name: canon
issue_stages:
  - id: po
    trigger_label: needs-po
    handler: po-handler
  - id: dev
    trigger_label: needs-dev
    handler: dev-handler
pr_stages:
  - id: review
    trigger_label: needs-review
    handler: review-handler
  - id: rework
    trigger_label: needs-rework
    handler: dev-rework-handler
  - id: qa
    trigger_label: needs-qa
    handler: qa-handler
  - id: merge
    trigger_label: qa-pass
    handler: merge-handler
YAML

    cat > "$LOOP_WORKFLOW_DIR/legacy.yaml" <<'YAML'
version: 1
name: legacy
issue_stages:
  - id: po
    trigger_label: po-review
    handler: po-handler
  - id: dev
    trigger_label: dev
    handler: dev-handler
pr_stages:
  - id: review
    trigger_label: review-pending
    handler: review-handler
  - id: rework
    trigger_label: changes-requested
    handler: dev-rework-handler
  - id: qa
    trigger_label: ready-for-qa
    handler: qa-handler
  - id: merge
    trigger_label: qa-pass
    handler: merge-handler
YAML

    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: oncanon
    name: Canon Workflow Project
    repo: owner/canon-repo
    root: /tmp/fake-canon
    default_branch: main
    workflow: canon
  - slug: onlegacy
    name: Legacy Workflow Project
    repo: owner/legacy-repo
    root: /tmp/fake-legacy
    default_branch: main
    workflow: legacy
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # Clear any per-test cache pollution.
    unset $(env | grep '^_LOOP_TRIGGER_CACHE_' | cut -d= -f1) 2>/dev/null || true

    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"
}

teardown() {
    unset $(env | grep '^_LOOP_TRIGGER_CACHE_' | cut -d= -f1) 2>/dev/null || true
    rm -rf "$LOOP_WORKFLOW_DIR" "$BATS_TMPDIR/fixture.yaml"
}

# canon workflow → needs-* canonical names
@test "canon workflow: needs-po IS issue trigger" {
    run loop_label_is_trigger oncanon issue needs-po
    [ "$status" -eq 0 ]
}

@test "canon workflow: po-review is NOT issue trigger" {
    run loop_label_is_trigger oncanon issue po-review
    [ "$status" -eq 1 ]
}

@test "canon workflow: needs-review IS pr trigger" {
    run loop_label_is_trigger oncanon pr needs-review
    [ "$status" -eq 0 ]
}

@test "canon workflow: review-pending is NOT pr trigger" {
    run loop_label_is_trigger oncanon pr review-pending
    [ "$status" -eq 1 ]
}

# legacy workflow → po-review/dev/review-pending/changes-requested/ready-for-qa
@test "legacy workflow: po-review IS issue trigger" {
    run loop_label_is_trigger onlegacy issue po-review
    [ "$status" -eq 0 ]
}

@test "legacy workflow: needs-po is NOT issue trigger" {
    run loop_label_is_trigger onlegacy issue needs-po
    [ "$status" -eq 1 ]
}

@test "legacy workflow: review-pending IS pr trigger" {
    run loop_label_is_trigger onlegacy pr review-pending
    [ "$status" -eq 0 ]
}

@test "legacy workflow: needs-review is NOT pr trigger" {
    run loop_label_is_trigger onlegacy pr needs-review
    [ "$status" -eq 1 ]
}

@test "qa-pass is shared trigger across both workflows" {
    # The merge stage uses qa-pass in both — this is the legitimate overlap.
    run loop_label_is_trigger oncanon   pr qa-pass
    [ "$status" -eq 0 ]
    run loop_label_is_trigger onlegacy pr qa-pass
    [ "$status" -eq 0 ]
}

@test "empty slug: returns 1 (caller-side opt-out)" {
    run loop_label_is_trigger "" issue needs-po
    [ "$status" -eq 1 ]
}

@test "kind issue vs pr: same label is trigger on one but not the other" {
    # In canon, needs-po is an ISSUE trigger but NOT a PR trigger.
    run loop_label_is_trigger oncanon issue needs-po
    [ "$status" -eq 0 ]
    run loop_label_is_trigger oncanon pr needs-po
    [ "$status" -eq 1 ]
}

@test "cache: a second call for the same (slug, kind) is served from cache" {
    # Prime the cache.
    loop_label_is_trigger oncanon issue needs-po

    # Mutate the workflow YAML out-from-under us. If caching works, the
    # cached value persists; the helper does NOT re-read the file.
    cat > "$LOOP_WORKFLOW_DIR/canon.yaml" <<'YAML'
version: 1
name: canon
issue_stages:
  - id: po
    trigger_label: completely-different-label
    handler: po-handler
pr_stages:
  - id: review
    trigger_label: also-different
    handler: review-handler
YAML

    # Cache hit returns the original answer (still treats needs-po as trigger).
    run loop_label_is_trigger oncanon issue needs-po
    [ "$status" -eq 0 ]
}
