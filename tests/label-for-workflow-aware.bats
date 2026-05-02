#!/usr/bin/env bats
# tests/label-for-workflow-aware.bats — coverage for #230.
#
# Verifies loop_label_for resolves the active workflow's stage trigger
# label, not just the verbatim canonical arg. Self-contained: synthesizes
# a fixture projects.yaml + workflow YAMLs (no dependency on in-tree config).

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
  - id: dev
    trigger_label: needs-dev
pr_stages:
  - id: review
    trigger_label: needs-review
  - id: rework
    trigger_label: needs-rework
  - id: qa
    trigger_label: needs-qa
  - id: merge
    trigger_label: qa-pass
YAML

    cat > "$LOOP_WORKFLOW_DIR/legacy.yaml" <<'YAML'
version: 1
name: legacy
issue_stages:
  - id: po
    trigger_label: po-review
  - id: dev
    trigger_label: dev
pr_stages:
  - id: review
    trigger_label: review-pending
  - id: rework
    trigger_label: changes-requested
  - id: qa
    trigger_label: ready-for-qa
  - id: merge
    trigger_label: qa-pass
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
  - slug: withoverride
    name: Override Project
    repo: owner/override-repo
    root: /tmp/fake-override
    default_branch: main
    workflow: canon
    labels:
      dev: custom-dev-label
      qa-pass: custom-merged
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"
}

teardown() {
    rm -rf "$LOOP_WORKFLOW_DIR" "$BATS_TMPDIR/fixture.yaml"
}

# canon workflow: legacy canonical 'dev' should map to 'needs-dev'
@test "canon workflow: 'dev' resolves to 'needs-dev' (#230 fix)" {
    run loop_label_for oncanon dev
    [ "$status" -eq 0 ]
    [ "$output" = "needs-dev" ]
}

@test "canon workflow: 'po-review' resolves to 'needs-po'" {
    run loop_label_for oncanon po-review
    [ "$status" -eq 0 ]
    [ "$output" = "needs-po" ]
}

@test "canon workflow: 'needs-review' stays 'needs-review' (already canonical)" {
    run loop_label_for oncanon needs-review
    [ "$status" -eq 0 ]
    [ "$output" = "needs-review" ]
}

@test "canon workflow: 'needs-rework' resolves to 'needs-rework' (canonical→rework stage)" {
    run loop_label_for oncanon needs-rework
    [ "$status" -eq 0 ]
    [ "$output" = "needs-rework" ]
}

@test "canon workflow: 'qa-pass' stays 'qa-pass' (canonical→merge stage)" {
    run loop_label_for oncanon qa-pass
    [ "$status" -eq 0 ]
    [ "$output" = "qa-pass" ]
}

# legacy workflow: canonical names should map to legacy triggers
@test "legacy workflow: 'dev' resolves to 'dev' (legacy trigger preserved)" {
    run loop_label_for onlegacy dev
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "legacy workflow: 'needs-dev' resolves to 'dev' (canonical → legacy trigger)" {
    run loop_label_for onlegacy needs-dev
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "legacy workflow: 'needs-review' resolves to 'review-pending'" {
    run loop_label_for onlegacy needs-review
    [ "$status" -eq 0 ]
    [ "$output" = "review-pending" ]
}

@test "legacy workflow: 'needs-rework' resolves to 'changes-requested'" {
    run loop_label_for onlegacy needs-rework
    [ "$status" -eq 0 ]
    [ "$output" = "changes-requested" ]
}

# project override takes precedence
@test "project override: literal 'dev' override beats workflow trigger" {
    run loop_label_for withoverride dev
    [ "$status" -eq 0 ]
    [ "$output" = "custom-dev-label" ]
}

@test "project override: 'qa-pass' override (override beats workflow)" {
    run loop_label_for withoverride qa-pass
    [ "$status" -eq 0 ]
    [ "$output" = "custom-merged" ]
}

# unknown canonical falls through to identity
@test "unknown canonical: 'qa-fail' (no stage map) returns verbatim" {
    run loop_label_for oncanon qa-fail
    [ "$status" -eq 0 ]
    [ "$output" = "qa-fail" ]
}

@test "unknown canonical: 'random-label' returns verbatim" {
    run loop_label_for oncanon random-label
    [ "$status" -eq 0 ]
    [ "$output" = "random-label" ]
}

# unknown slug returns canonical (no workflow to consult)
@test "unknown slug: 'dev' returns 'dev' verbatim" {
    run loop_label_for nonexistent dev
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}
