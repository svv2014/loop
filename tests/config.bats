#!/usr/bin/env bats
# tests/config.bats — unit tests for lib/config.sh (v1 schema parsing).
# Uses temporary YAML fixtures; does not touch config/projects.yaml.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    FIXTURES_DIR="$BATS_TMPDIR/fixtures"
    mkdir -p "$FIXTURES_DIR"

    # Point loop_load_project at the temp config.
    export LOOP_CONFIG="$FIXTURES_DIR/projects.yaml"

    # shellcheck source=../lib/config.sh
    source "$REPO_ROOT/lib/config.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/fixtures" 2>/dev/null || true
    unset LOOP_CONFIG NAME REPO ROOT DEFAULT_BRANCH COMMIT_PREFIX
    unset DEV_VALIDATION_CMD QA_VALIDATION_CMD MERGE_STRATEGY AUTO_REBASE
    unset BACKEND MAX_CONCURRENT_PRS LOOP_AGENT_MODEL ALLOWED_AUTHORS
    unset WORKFLOW LOOP_LABEL_OVERRIDES
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: write a minimal v1 projects.yaml fixture
# ─────────────────────────────────────────────────────────────────────────────

write_fixture() {
    cat > "$LOOP_CONFIG"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1 — default workflow (no workflow key → WORKFLOW=default)
# ─────────────────────────────────────────────────────────────────────────────

@test "v1: WORKFLOW defaults to 'default' when workflow key is absent" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Test Project
    slug: testproj
    repo: owner/test-project
    root: /tmp/testproj
    default_branch: main
    dev:
      commit_prefix: TEST
YAML

    loop_load_project "testproj"
    [ "$WORKFLOW" = "default" ]
}

@test "v1: basic fields are parsed correctly with default workflow" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Test Project
    slug: testproj
    repo: owner/test-project
    root: /tmp/testproj
    default_branch: main
    dev:
      commit_prefix: TEST
YAML

    loop_load_project "testproj"
    [ "$REPO" = "owner/test-project" ]
    [ "$DEFAULT_BRANCH" = "main" ]
    [ "$COMMIT_PREFIX" = "TEST" ]
    [ "$BACKEND" = "github" ]
}

@test "v1: LOOP_LABEL_OVERRIDES is empty string when no labels key" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Test Project
    slug: testproj
    repo: owner/test-project
    root: /tmp/testproj
    default_branch: main
YAML

    loop_load_project "testproj"
    [ "$LOOP_LABEL_OVERRIDES" = "" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# v1 — custom workflow ref
# ─────────────────────────────────────────────────────────────────────────────

@test "v1: WORKFLOW is set to the value of the workflow key" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Minimal Project
    slug: minproj
    repo: owner/min-project
    root: /tmp/minproj
    default_branch: main
    workflow: minimal
YAML

    loop_load_project "minproj"
    [ "$WORKFLOW" = "minimal" ]
}

@test "v1: WORKFLOW accepts 'current' as a valid workflow name" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Legacy Project
    slug: legproj
    repo: owner/leg-project
    root: /tmp/legproj
    default_branch: main
    workflow: current
YAML

    loop_load_project "legproj"
    [ "$WORKFLOW" = "current" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# v1 — label overrides
# ─────────────────────────────────────────────────────────────────────────────

@test "v1: single label override is exported in LOOP_LABEL_OVERRIDES" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Override Project
    slug: ovproj
    repo: owner/ov-project
    root: /tmp/ovproj
    default_branch: main
    labels:
      plan: dev
YAML

    loop_load_project "ovproj"
    [[ "$LOOP_LABEL_OVERRIDES" == *"plan=dev"* ]]
}

@test "v1: multiple label overrides are all present in LOOP_LABEL_OVERRIDES" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Override Project
    slug: ovproj
    repo: owner/ov-project
    root: /tmp/ovproj
    default_branch: main
    labels:
      plan: dev
      qa-pass: approved
      qa-fail: qa-failed
YAML

    loop_load_project "ovproj"
    [[ "$LOOP_LABEL_OVERRIDES" == *"plan=dev"* ]]
    [[ "$LOOP_LABEL_OVERRIDES" == *"qa-pass=approved"* ]]
    [[ "$LOOP_LABEL_OVERRIDES" == *"qa-fail=qa-failed"* ]]
}

@test "v1: label overrides use pipe as separator" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Override Project
    slug: ovproj
    repo: owner/ov-project
    root: /tmp/ovproj
    default_branch: main
    labels:
      plan: dev
      needs-review: review
YAML

    loop_load_project "ovproj"
    # At least one pipe separator must be present for two overrides
    [[ "$LOOP_LABEL_OVERRIDES" == *"|"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# v0 legacy fallback — no version field
# ─────────────────────────────────────────────────────────────────────────────

@test "v0: loads project successfully even when version field is absent" {
    write_fixture <<'YAML'
projects:
  - name: Legacy Project
    slug: legacyproj
    repo: owner/legacy-project
    root: /tmp/legacyproj
    default_branch: main
    dev:
      commit_prefix: LEG
YAML

    loop_load_project "legacyproj"
    [ "$REPO" = "owner/legacy-project" ]
    [ "$COMMIT_PREFIX" = "LEG" ]
}

@test "v0: WORKFLOW defaults to 'default' when version field is absent" {
    write_fixture <<'YAML'
projects:
  - name: Legacy Project
    slug: legacyproj
    repo: owner/legacy-project
    root: /tmp/legacyproj
    default_branch: main
YAML

    loop_load_project "legacyproj"
    [ "$WORKFLOW" = "default" ]
}

@test "v0: emits deprecation warning to stderr when version field is absent" {
    write_fixture <<'YAML'
projects:
  - name: Legacy Project
    slug: legacyproj
    repo: owner/legacy-project
    root: /tmp/legacyproj
    default_branch: main
YAML

    run loop_load_project "legacyproj"
    # Exit should still be 0 (project found)
    [ "$status" -eq 0 ]
    # Warning must appear somewhere in combined output
    [[ "$output" == *"v0"* ]] || [[ "$output" == *"legacy"* ]] || [[ "$output" == *"version"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Error cases
# ─────────────────────────────────────────────────────────────────────────────

@test "loop_load_project: returns non-zero for unknown slug" {
    write_fixture <<'YAML'
version: 1
projects:
  - name: Test
    slug: known
    repo: owner/test
    root: /tmp/test
    default_branch: main
YAML

    run loop_load_project "unknown-slug"
    [ "$status" -ne 0 ]
}

@test "loop_load_project: returns 2 when config file is missing" {
    export LOOP_CONFIG="/tmp/nonexistent-config-$$.yaml"
    run loop_load_project "anything"
    [ "$status" -eq 2 ]
}
