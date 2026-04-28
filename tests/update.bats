#!/usr/bin/env bats
# tests/update.bats — tests for scripts/update.sh breaking-change gate.
#
# We exercise the Python extraction logic directly by feeding synthetic
# CHANGELOG diffs and checking the exit code + output of update.sh.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    UPDATE_SH="$REPO_ROOT/scripts/update.sh"

    # Scratch dir for a fake git repo
    FAKE_REPO="$BATS_TMPDIR/fake-repo"
    rm -rf "$FAKE_REPO"
    mkdir -p "$FAKE_REPO"
    cd "$FAKE_REPO"

    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"

    # Base CHANGELOG with no breaking entries
    cat > CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-04-27

### Added
- Initial release.

[0.1.0]: https://github.com/example/repo/releases/tag/v0.1.0
EOF
    echo "0.1.0" > VERSION
    git add .
    git commit -q -m "init"

    # Simulate origin/main with a new commit that has a BREAKING: entry
    git checkout -q -b origin-main
    cat > CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] - 2026-05-12

### Changed
- BREAKING: workflow YAML schema bumped to v2 — see migration recipe.

## [0.1.0] - 2026-04-27

### Added
- Initial release.

[Unreleased]: https://github.com/example/repo/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/example/repo/releases/tag/v0.2.0
[0.1.0]: https://github.com/example/repo/releases/tag/v0.1.0
EOF
    echo "0.2.0" > VERSION
    git add .
    git commit -q -m "release: v0.2.0"

    # Return to main; register "origin" as the local origin-main branch
    git checkout -q main
    git remote add origin "$FAKE_REPO"
    git fetch origin origin-main:refs/remotes/origin/main -q
}

teardown() {
    rm -rf "$FAKE_REPO" 2>/dev/null || true
}

# ── helper to run update.sh inside the fake repo ─────────────────────────────
run_update() {
    run bash "$UPDATE_SH" "$@"
}

# ── tests ─────────────────────────────────────────────────────────────────────

@test "update: halts when BREAKING: present and --yes not given" {
    cd "$FAKE_REPO"
    git checkout -q main
    run_update
    [ "$status" -eq 1 ]
    [[ "$output" == *"⚠ This update contains breaking changes:"* ]]
    [[ "$output" == *"BREAKING:"* ]]
    [[ "$output" == *"--yes"* ]]
}

@test "update: output includes version header and breaking line" {
    cd "$FAKE_REPO"
    git checkout -q main
    run_update
    [[ "$output" == *"0.2.0"* ]]
    [[ "$output" == *"BREAKING: workflow YAML schema bumped to v2"* ]]
}

@test "update: applies when --yes is given with breaking changes" {
    cd "$FAKE_REPO"
    git checkout -q main
    run_update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"done"* ]]
    [ "$(cat VERSION)" = "0.2.0" ]
}

@test "update: --check shows changelog and does not apply" {
    cd "$FAKE_REPO"
    git checkout -q main
    run_update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"BREAKING:"* ]]
    # Version file must not have changed (not applied)
    [ "$(cat VERSION)" = "0.1.0" ]
}

@test "update: no breaking changes — applies without --yes" {
    # Create a fake repo where the new commit has no BREAKING: line
    SAFE_REPO="$BATS_TMPDIR/safe-repo"
    rm -rf "$SAFE_REPO"
    mkdir -p "$SAFE_REPO"
    cd "$SAFE_REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "0.1.0" > VERSION
    echo "# Changelog" > CHANGELOG.md
    git add .
    git commit -q -m "init"

    git checkout -q -b origin-main
    echo "0.1.1" > VERSION
    git add .
    git commit -q -m "patch"

    git checkout -q main
    git remote add origin "$SAFE_REPO"
    git fetch origin origin-main:refs/remotes/origin/main -q

    run bash "$UPDATE_SH"
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "0.1.1" ]
}

@test "update: reports already up to date when nothing to fetch" {
    cd "$FAKE_REPO"
    git checkout -q main
    # Advance main to match origin
    git merge --ff-only origin/main -q
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
}
