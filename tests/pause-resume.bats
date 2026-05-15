#!/usr/bin/env bats
# tests/pause-resume.bats — QA-driven tests for pause/resume helpers in lib/config.sh.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Isolated state dir per test run.
    export LOOP_STATE_DIR="$BATS_TMPDIR/state"
    mkdir -p "$LOOP_STATE_DIR"

    # Point loop_load_project at a temp config with two known slugs.
    export LOOP_CONFIG="$BATS_TMPDIR/projects.yaml"
    cat > "$LOOP_CONFIG" <<'YAML'
version: 1
projects:
  - name: Alpha
    slug: alpha
    repo: owner/alpha
    root: /tmp/alpha
    default_branch: main
    dev:
      commit_prefix: ALPHA
  - name: Beta
    slug: beta
    repo: owner/beta
    root: /tmp/beta
    default_branch: main
    dev:
      commit_prefix: BETA
YAML

    # Reload config.sh so LOOP_PAUSED_STATE_FILE picks up the new LOOP_STATE_DIR.
    # shellcheck source=../lib/config.sh
    source "$REPO_ROOT/lib/config.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/projects.yaml" 2>/dev/null || true
    unset LOOP_CONFIG LOOP_STATE_DIR LOOP_PAUSED_STATE_FILE
}

# ── loop_project_is_paused ────────────────────────────────────────────────────

@test "loop_project_is_paused: returns 1 when state file does not exist" {
    rm -f "$LOOP_PAUSED_STATE_FILE"
    run loop_project_is_paused "alpha"
    [ "$status" -eq 1 ]
}

@test "loop_project_is_paused: returns 1 for active project when file exists" {
    printf 'beta\n' > "$LOOP_PAUSED_STATE_FILE"
    run loop_project_is_paused "alpha"
    [ "$status" -eq 1 ]
}

@test "loop_project_is_paused: returns 0 for paused project" {
    printf 'alpha\n' > "$LOOP_PAUSED_STATE_FILE"
    run loop_project_is_paused "alpha"
    [ "$status" -eq 0 ]
}

@test "loop_project_is_paused: does not match a slug that is a prefix of another" {
    printf 'alpha-extended\n' > "$LOOP_PAUSED_STATE_FILE"
    run loop_project_is_paused "alpha"
    [ "$status" -eq 1 ]
}

# ── loop_project_set_paused ───────────────────────────────────────────────────

@test "loop_project_set_paused: rejects unknown slug and exits non-zero" {
    run loop_project_set_paused "nonexistent-slug"
    [ "$status" -ne 0 ]
    [ ! -f "$LOOP_PAUSED_STATE_FILE" ]
}

@test "loop_project_set_paused: adds known slug to state file" {
    loop_project_set_paused "alpha"
    grep -Fxq "alpha" "$LOOP_PAUSED_STATE_FILE"
}

@test "loop_project_set_paused: idempotent — duplicate entries are not written" {
    loop_project_set_paused "alpha"
    loop_project_set_paused "alpha"
    count=$(grep -cxF "alpha" "$LOOP_PAUSED_STATE_FILE")
    [ "$count" -eq 1 ]
}

@test "loop_project_set_paused: state file is sorted and deduped after multiple pauses" {
    loop_project_set_paused "beta"
    loop_project_set_paused "alpha"
    first=$(head -1 "$LOOP_PAUSED_STATE_FILE")
    [ "$first" = "alpha" ]
}

# ── loop_project_clear_paused ─────────────────────────────────────────────────

@test "loop_project_clear_paused: no-op when state file does not exist" {
    rm -f "$LOOP_PAUSED_STATE_FILE"
    run loop_project_clear_paused "alpha"
    [ "$status" -eq 0 ]
}

@test "loop_project_clear_paused: no-op when slug is not paused" {
    printf 'beta\n' > "$LOOP_PAUSED_STATE_FILE"
    loop_project_clear_paused "alpha"
    grep -Fxq "beta" "$LOOP_PAUSED_STATE_FILE"
}

@test "loop_project_clear_paused: removes slug from state file" {
    printf 'alpha\nbeta\n' > "$LOOP_PAUSED_STATE_FILE"
    loop_project_clear_paused "alpha"
    ! grep -Fxq "alpha" "$LOOP_PAUSED_STATE_FILE"
    grep -Fxq "beta" "$LOOP_PAUSED_STATE_FILE"
}

# ── round-trip: pause → list → resume → list ─────────────────────────────────

@test "round-trip: pause alpha, verify paused, resume, verify active" {
    # Initially not paused
    run loop_project_is_paused "alpha"
    [ "$status" -eq 1 ]

    # Pause
    loop_project_set_paused "alpha"
    run loop_project_is_paused "alpha"
    [ "$status" -eq 0 ]

    # Beta stays active
    run loop_project_is_paused "beta"
    [ "$status" -eq 1 ]

    # Resume
    loop_project_clear_paused "alpha"
    run loop_project_is_paused "alpha"
    [ "$status" -eq 1 ]
}
