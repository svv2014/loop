#!/usr/bin/env bats
# tests/update.bats — tests for scripts/update.sh breaking-change gate.
#
# Each test builds minimal fake git repos so no network access is required.
# LOOP_ROOT is injected so update.sh operates on the fake repo, not the real one.
#
# Topology:
#   FAKE_ORIGIN  main: 0.1.0 → 0.2.0(BREAKING)   ← the "remote"
#   FAKE_CORE    main: 0.1.0 (clone of FAKE_ORIGIN, reset to old commit)
#
# Histories are shared, so git fetch + git merge --ff-only work without
# --allow-unrelated-histories.  update.sh's `git fetch origin main` hits
# FAKE_ORIGIN (not FAKE_CORE itself), so refs/remotes/origin/main correctly
# stays at 0.2.0.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    UPDATE_SH="$REPO_ROOT/scripts/update.sh"

    # ── 1. Build FAKE_ORIGIN with a linear history: 0.1.0 → 0.2.0(BREAKING) ──
    local FAKE_ORIGIN="$BATS_TMPDIR/fake-origin"
    rm -rf "$FAKE_ORIGIN"
    mkdir -p "$FAKE_ORIGIN"
    cd "$FAKE_ORIGIN"
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
    # Ensure branch is named 'main' regardless of git default (pre-2.28 uses 'master')
    git branch -M main 2>/dev/null || true

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
    # FAKE_ORIGIN/main is now at 0.2.0

    # ── 2. Clone FAKE_ORIGIN → FAKE_CORE, then reset to 0.1.0 ────────────────
    # Cloning gives shared history; reset moves local main back one commit.
    # refs/remotes/origin/main in FAKE_CORE still points at the 0.2.0 commit.
    FAKE_CORE="$BATS_TMPDIR/fake-core"
    rm -rf "$FAKE_CORE"
    git clone -q "$FAKE_ORIGIN" "$FAKE_CORE"
    cd "$FAKE_CORE"
    git config user.email "test@example.com"
    git config user.name "Test"
    git reset --hard HEAD~1 -q
    # Now: FAKE_CORE/main → 0.1.0, FAKE_CORE origin/main → 0.2.0 ✓
}

teardown() {
    rm -rf "$BATS_TMPDIR/fake-core" "$BATS_TMPDIR/fake-origin" \
           "$BATS_TMPDIR/fake-monitor" "$BATS_TMPDIR/fake-monitor-origin" 2>/dev/null || true
}

# ── helpers ───────────────────────────────────────────────────────────────────

# Run update.sh with LOOP_ROOT pointed at the fake core repo.
run_update() {
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" \
        bash "$UPDATE_SH" "$@"
}

# Build a fake monitor repo at $BATS_TMPDIR/fake-monitor (with its own origin).
# $1 = "breaking" | "clean" — controls whether origin/main has a BREAKING: line.
_make_monitor() {
    local kind="${1:-clean}"
    local FAKE_MON_ORIGIN="$BATS_TMPDIR/fake-monitor-origin"
    local FAKE_MON="$BATS_TMPDIR/fake-monitor"

    # Build monitor origin with 0.1.0 → bump
    rm -rf "$FAKE_MON_ORIGIN"
    mkdir -p "$FAKE_MON_ORIGIN"
    cd "$FAKE_MON_ORIGIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "# Changelog" > CHANGELOG.md
    echo "0.1.0" > VERSION
    git add .; git commit -q -m "init"
    git branch -M main 2>/dev/null || true

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
    git add .; git commit -q -m "bump"
    # FAKE_MON_ORIGIN/main is now at 0.2.0 or 0.1.1

    # Clone FAKE_MON_ORIGIN → FAKE_MON, reset to 0.1.0
    rm -rf "$FAKE_MON"
    git clone -q "$FAKE_MON_ORIGIN" "$FAKE_MON"
    cd "$FAKE_MON"
    git config user.email "test@example.com"
    git config user.name "Test"
    git reset --hard HEAD~1 -q

    cd "$FAKE_CORE"
}

# ── core-only tests ───────────────────────────────────────────────────────────

@test "core: halts on BREAKING: without --yes" {
    run_update
    [ "$status" -eq 1 ]
    [[ "$output" == *"⚠ This update contains breaking changes:"* ]]
    [[ "$output" == *"BREAKING:"* ]]
    [[ "$output" == *"--yes"* ]]
}

@test "core: output includes version header and breaking line text" {
    run_update
    [[ "$output" == *"0.2.0"* ]]
    [[ "$output" == *"BREAKING: workflow YAML schema bumped to v2"* ]]
}

@test "core: --yes bypasses gate and applies" {
    run_update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"done"* ]]
    [ "$(cat "$FAKE_CORE/VERSION")" = "0.2.0" ]
}

@test "core: --check shows changelog and does not apply" {
    run_update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"BREAKING:"* ]]
    [ "$(cat "$FAKE_CORE/VERSION")" = "0.1.0" ]
}

@test "core: --dry-run is alias for --check" {
    run_update --dry-run
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_CORE/VERSION")" = "0.1.0" ]
}

@test "core: no BREAKING: — applies without --yes" {
    local SAFE_ORIGIN="$BATS_TMPDIR/safe-origin"
    local SAFE="$BATS_TMPDIR/safe-core"

    # Build SAFE_ORIGIN with 0.1.0 → 0.1.1 (no BREAKING:)
    rm -rf "$SAFE_ORIGIN"; mkdir -p "$SAFE_ORIGIN"; cd "$SAFE_ORIGIN"
    git init -q
    git config user.email "test@example.com"; git config user.name "Test"
    echo "0.1.0" > VERSION; echo "# Changelog" > CHANGELOG.md
    git add .; git commit -q -m "init"
    git branch -M main 2>/dev/null || true
    echo "0.1.1" > VERSION; git add .; git commit -q -m "patch"

    # Clone to SAFE and reset to 0.1.0
    rm -rf "$SAFE"
    git clone -q "$SAFE_ORIGIN" "$SAFE"
    cd "$SAFE"
    git config user.email "test@example.com"; git config user.name "Test"
    git reset --hard HEAD~1 -q

    run env -i HOME="$HOME" PATH="$PATH" LOOP_ROOT="$SAFE" bash "$UPDATE_SH"
    [ "$status" -eq 0 ]
    [ "$(cat "$SAFE/VERSION")" = "0.1.1" ]
    rm -rf "$SAFE" "$SAFE_ORIGIN"
}

@test "core: already up to date exits cleanly" {
    cd "$FAKE_CORE" && git merge --ff-only origin/main -q
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
}

# ── per-component (monitor) tests ─────────────────────────────────────────────

@test "monitor: BREAKING: in monitor also halts without --yes" {
    _make_monitor breaking
    # Advance core to be up-to-date so only monitor triggers
    cd "$FAKE_CORE" && git merge --ff-only origin/main -q
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"⚠ This update contains breaking changes:"* ]]
    [[ "$output" == *"BREAKING:"* ]]
}

@test "monitor: output labels monitor section separately" {
    _make_monitor breaking
    cd "$FAKE_CORE" && git merge --ff-only origin/main -q
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [[ "$output" == *"[loop-monitor]"* ]]
    [[ "$output" == *"BREAKING: LOOP_MONITOR_URL renamed to LOOP_BOUNTY_URL"* ]]
}

@test "monitor: --yes applies both core and monitor" {
    _make_monitor breaking
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH" --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_CORE/VERSION")" = "0.2.0" ]
    [ "$(cat "$FAKE_MON/VERSION")" = "0.2.0" ]
}

@test "monitor: both components BREAKING: — combined output shown" {
    _make_monitor breaking
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[loop core]"* ]]
    [[ "$output" == *"[loop-monitor]"* ]]
}

@test "monitor: clean monitor with BREAKING: core — only core warned" {
    _make_monitor clean
    FAKE_MON="$BATS_TMPDIR/fake-monitor"
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" LOOP_MONITOR_ROOT="$FAKE_MON" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[loop core]"* ]]
    [[ "$output" != *"[loop-monitor]"* ]]
}

@test "monitor: LOOP_MONITOR_ROOT not set — monitor skipped silently" {
    run_update
    [ "$status" -eq 1 ]
    [[ "$output" != *"loop-monitor"* ]]
}

@test "monitor: LOOP_MONITOR_ROOT set to non-git dir — monitor skipped silently" {
    run env -i HOME="$HOME" PATH="$PATH" \
        LOOP_ROOT="$FAKE_CORE" LOOP_MONITOR_ROOT="$BATS_TMPDIR/nonexistent" \
        bash "$UPDATE_SH"
    [ "$status" -eq 1 ]
    [[ "$output" != *"loop-monitor"* ]]
}
