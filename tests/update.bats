#!/usr/bin/env bats
# tests/update.bats — tests for scripts/update.sh breaking-change gate.
#
# Each test builds minimal fake git repos so no network access is required.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    UPDATE_SH="$REPO_ROOT/scripts/update.sh"

    # Build a fake loop core repo with a BREAKING: entry in origin.
    FAKE_CORE="$BATS_TMPDIR/fake-core"
    rm -rf "$FAKE_CORE"
    mkdir -p "$FAKE_CORE"
    cd "$FAKE_CORE"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    cat > CHANGELOG.md <<'EOF'
# Changelog
## [0.1.0] - 2026-04-27
### Added
- Initial release.
EOF
    echo "0.1.0" > VERSION
    git add .
    git commit -q -m "init"

    # Simulate origin/main with a BREAKING: entry
    git checkout -q -b origin-main
    cat > CHANGELOG.md <<'EOF'
# Changelog
## [0.2.0] - 2026-05-12
### Changed
- BREAKING: workflow YAML schema bumped to v2 — add version: 2 to config files.
## [0.1.0] - 2026-04-27
### Added
- Initial release.
EOF
    echo "0.2.0" > VERSION
    git add .
    git commit -q -m "release: v0.2.0"

    git checkout -q main
    git remote add origin "$FAKE_CORE"
    git fetch origin origin-main:refs/remotes/origin/main -q
}

teardown() {
    rm -rf "$BATS_TMPDIR/fake-core" "$BATS_TMPDIR/fake-monitor" 2>/dev/null || true
}

# ── helpers ───────────────────────────────────────────────────────────────────

# Run update.sh inside FAKE_CORE with optional extra env vars.
run_update() {
    run env -i HOME="$HOME" PATH="$PATH" \
        bash "$UPDATE_SH" "$@"
}

# Build a fake monitor repo at $BATS_TMPDIR/fake-monitor.
# $1 = "breaking" | "clean" — controls whether origin/main has a BREAKING: line.
_make_monitor() {
    local kind="${1:-clean}"
    local FAKE_MON="$BATS_TMPDIR/fake-monitor"
    rm -rf "$FAKE_MON"
    mkdir -p "$FAKE_MON"
    cd "$FAKE_MON"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "# Changelog" > CHANGELOG.md
    echo "0.1.0" > VERSION
    git add .
    git commit -q -m "init"

    git checkout -q -b origin-main
    if [ "$kind" = "breaking" ]; then
        cat > CHANGELOG.md <<'EOF'
# Changelog
## [0.2.0] - 2026-05-12
### Changed
- BREAKING: LOOP_MONITOR_URL renamed to LOOP_BOUNTY_URL. Update loop.env.
## [0.1.0] - 2026-04-27
### Added
- Initial release.
EOF
        echo "0.2.0" > VERSION
    else
        echo "0.1.1" > VERSION
    fi
    git add .
    git commit -q -m "bump"

    git checkout -q main
    git remote add origin "$FAKE_MON"
    git fetch origin origin-main:refs/remotes/origin/main -q
    cd "$FAKE_CORE"
}

# ── core-only tests ───────────────────────────────────────────────────────────

@test "core: halts on BREAKING: without --yes" {
    cd "$FAKE_CORE"
    run_update
    [ "$status" -eq 1 ]
    [[ "$output" == *"⚠ This update contains breaking changes:"* ]]
    [[ "$output" == *"BREAKING:"* ]]
    [[ "$output" == *"--yes"* ]]
}

@test "core: output includes version header and breaking line text" {
    cd "$FAKE_CORE"
    run_update
    [[ "$output" == *"0.2.0"* ]]
    [[ "$output" == *"BREAKING: workflow YAML schema bumped to v2"* ]]
}

@test "core: --yes bypasses gate and applies" {
    cd "$FAKE_CORE"
    run_update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"done"* ]]
    [ "$(cat VERSION)" = "0.2.0" ]
}

@test "core: --check shows changelog and does not apply" {
    cd "$FAKE_CORE"
    run_update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"BREAKING:"* ]]
    [ "$(cat VERSION)" = "0.1.0" ]
}

@test "core: --dry-run is alias for --check" {
    cd "$FAKE_CORE"
    run_update --dry-run
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "0.1.0" ]
}

@test "core: no BREAKING: — applies without --yes" {
    local SAFE="$BATS_TMPDIR/safe-core"
    rm -rf "$SAFE"; mkdir -p "$SAFE"; cd "$SAFE"
    git init -q
    git config user.email "test@example.com"; git config user.name "Test"
    echo "0.1.0" > VERSION; echo "# Changelog" > CHANGELOG.md
    git add .; git commit -q -m "init"
    git checkout -q -b origin-main
    echo "0.1.1" > VERSION; git add .; git commit -q -m "patch"
    git checkout -q main
    git remote add origin "$SAFE"
    git fetch origin origin-main:refs/remotes/origin/main -q

    run env -i HOME="$HOME" PATH="$PATH" bash "$UPDATE_SH"
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "0.1.1" ]
    rm -rf "$SAFE"
}

@test "core: already up to date exits cleanly" {
    cd "$FAKE_CORE"
    git merge --ff-only origin/main -q
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
}

# ── per-component (monitor) tests ─────────────────────────────────────────────

@test "monitor: BREAKING: in monitor also halts without --yes" {
    _make_monitor breaking
    cd "$FAKE_CORE"
    # Advance core to be up-to-date so only monitor triggers
    git merge --ff-only origin/main -q
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"⚠ This update contains breaking changes:"* ]]
    [[ "$output" == *"BREAKING:"* ]]
}

@test "monitor: output labels monitor section separately" {
    _make_monitor breaking
    cd "$FAKE_CORE"
    git merge --ff-only origin/main -q
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [[ "$output" == *"[loop-monitor]"* ]]
    [[ "$output" == *"BREAKING: LOOP_MONITOR_URL renamed to LOOP_BOUNTY_URL"* ]]
}

@test "monitor: --yes applies both core and monitor" {
    _make_monitor breaking
    cd "$FAKE_CORE"
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH" --yes
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "0.2.0" ]
    [ "$(cat "$FAKE_MON/VERSION")" = "0.2.0" ]
}

@test "monitor: both components BREAKING: — combined output shown" {
    _make_monitor breaking
    cd "$FAKE_CORE"
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[loop core]"* ]]
    [[ "$output" == *"[loop-monitor]"* ]]
}

@test "monitor: clean monitor with BREAKING: core — only core warned" {
    _make_monitor clean
    cd "$FAKE_CORE"
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[loop core]"* ]]
    [[ "$output" != *"[loop-monitor]"* ]]
}

@test "monitor: LOOP_MONITOR_ROOT not set — monitor skipped silently" {
    cd "$FAKE_CORE"
    run env -i HOME="$HOME" PATH="$PATH" bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" != *"loop-monitor"* ]]
}

@test "monitor: LOOP_MONITOR_ROOT set to non-git dir — monitor skipped silently" {
    cd "$FAKE_CORE"
    run env -i HOME="$HOME" PATH="$PATH" LOOP_MONITOR_ROOT="$BATS_TMPDIR/nonexistent" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    # Should still gate on core breaking, but no monitor lines
    [[ "$output" != *"loop-monitor"* ]]
}
