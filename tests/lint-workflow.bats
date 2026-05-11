#!/usr/bin/env bats
# tests/lint-workflow.bats — unit tests for scripts/lint-workflow.sh.
# Exercises the state-machine audit against synthetic workflow YAMLs.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LINT="$REPO_ROOT/scripts/lint-workflow.sh"
    TMP_DIR="$(mktemp -d "$BATS_TMPDIR/lintwf-XXXXXX")"
}

teardown() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Bundled workflow files must all pass clean.
# ---------------------------------------------------------------------------

@test "all bundled workflows pass lint" {
    run "$LINT"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Dead-end detection: qa-fail set but never triggered (the bug we shipped).
# ---------------------------------------------------------------------------

@test "detects qa-fail dead-end" {
    cat > "$TMP_DIR/dead.yaml" <<'EOF'
version: 1
name: dead
issue_stages:
  - id: dev
    trigger_label: needs-dev
    handler: dev-handler
    on_done: needs-review
pr_stages:
  - id: review
    trigger_label: needs-review
    handler: review-handler
    decisions:
      approve: qa-pass
      reject: qa-fail
  - id: merge
    trigger_label: qa-pass
    handler: merge-handler
    on_done: done
EOF
    run "$LINT" "$TMP_DIR/dead.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dead-end label 'qa-fail'"* ]]
}

# ---------------------------------------------------------------------------
# Orphan trigger detection: a stage triggered by a label no one sets.
# ---------------------------------------------------------------------------

@test "detects orphan trigger" {
    cat > "$TMP_DIR/orphan.yaml" <<'EOF'
version: 1
name: orphan
issue_stages:
  - id: dev
    trigger_label: needs-dev
    handler: dev-handler
    on_done: needs-review
pr_stages:
  - id: review
    trigger_label: needs-review
    handler: review-handler
    decisions:
      approve: qa-pass
      reject: needs-dev
  - id: merge
    trigger_label: qa-pass
    handler: merge-handler
    on_done: done
  - id: ghost
    trigger_label: nobody-sets-this
    handler: noop-handler
    on_done: done
EOF
    run "$LINT" "$TMP_DIR/orphan.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"orphan trigger 'nobody-sets-this'"* ]]
}

# ---------------------------------------------------------------------------
# Entry-point trigger (first issue stage) is NOT treated as orphan even
# though no handler in the workflow produces it.
# ---------------------------------------------------------------------------

@test "first-stage trigger is treated as entry point, not orphan" {
    cat > "$TMP_DIR/entry.yaml" <<'EOF'
version: 1
name: entry
issue_stages:
  - id: dev
    trigger_label: needs-dev
    handler: dev-handler
    on_done: done
EOF
    run "$LINT" "$TMP_DIR/entry.yaml"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Terminal labels (done / blocked / needs-clarification) are valid sinks.
# ---------------------------------------------------------------------------

@test "terminal labels are valid sinks" {
    cat > "$TMP_DIR/term.yaml" <<'EOF'
version: 1
name: term
issue_stages:
  - id: po
    trigger_label: needs-po
    handler: po-handler
    on_done: needs-dev
    on_blocked: blocked
    on_clarification: needs-clarification
  - id: dev
    trigger_label: needs-dev
    handler: dev-handler
    on_done: done
    on_failed_after_max: blocked
EOF
    run "$LINT" "$TMP_DIR/term.yaml"
    [ "$status" -eq 0 ]
}
