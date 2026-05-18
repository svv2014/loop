#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written on every tick.
#
# Verifies that scanner.sh's run_once() touches the heartbeat file on every
# tick, and that check-scanner-liveness.sh correctly classifies fresh vs stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh binary so env.sh / config.sh loading doesn't fail.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh definitions (same approach as scanner.bats).
    local _src="$BATS_TMPDIR/scanner-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        awk '
            /^SCRIPT_DIR=/           { next }
            /^LOOP_ROOT=/            { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=false"; print "ONCE=false"; next }
            skip && /^done$/         { skip=0; next }
            skip                     { next }
            /^acquire_lock$/         { exit }
            { print }
        ' "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Override paths set by scanner.sh after source (env.sh may have read
    # a local loop.env with different values — set explicitly here).
    HEARTBEAT_FILE="$BATS_TMPDIR/scanner-heartbeat"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() / dispatch_direct so run_once() doesn't emit real work.
    log() { :; }
    dispatch_direct() { :; }
    # Stub out functions that would call gh or python3 to list projects.
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/dedup" "$BATS_TMPDIR/scanner-src.sh" \
           "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-heartbeat" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file: written on every tick
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file on first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: updates heartbeat mtime on subsequent ticks" {
    touch -t 200001010000 "$HEARTBEAT_FILE"   # backdate to year 2000
    local before
    before=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    run_once
    local after
    after=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$after" -gt "$before" ]
}

@test "run_once: heartbeat file is not written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# check-scanner-liveness.sh: source-level logic tests
# ---------------------------------------------------------------------------

@test "check-scanner-liveness: fresh heartbeat file is not stale" {
    local hb="$BATS_TMPDIR/hb-fresh"
    touch "$hb"
    local age
    age=$(( $(date +%s) - $(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0) ))
    # Threshold of 600s; a just-created file has age ~0
    [ "$age" -lt 600 ]
}

@test "check-scanner-liveness: backdated heartbeat exceeds threshold" {
    local hb="$BATS_TMPDIR/hb-stale"
    touch -t 200001010000 "$hb"   # year 2000 → thousands of seconds old
    local age threshold=600
    age=$(( $(date +%s) - $(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0) ))
    [ "$age" -ge "$threshold" ]
}

@test "check-scanner-liveness.sh: exits 0 with OK message for fresh heartbeat" {
    local hb="$BATS_TMPDIR/logs/scanner-heartbeat"
    touch "$hb"
    # Run with an isolated LOOP_ROOT pointing at a loop.env-free dir so env.sh
    # does not source the operator's loop.env and override LOOP_LOG_DIR.
    local fake_root="$BATS_TMPDIR/fakeroot"
    mkdir -p "$fake_root/lib" "$fake_root/config"
    # Symlink only what we need: env.sh (for LOOP_LOG_DIR export), no loop.env.
    ln -sf "$REPO_ROOT/lib/env.sh"      "$fake_root/lib/env.sh"
    ln -sf "$REPO_ROOT/lib/version.sh"  "$fake_root/lib/version.sh"
    ln -sf "$REPO_ROOT/lib/workflow.sh" "$fake_root/lib/workflow.sh"
    ln -sf "$REPO_ROOT/config/workflows" "$fake_root/config/workflows"
    # Build a minimal scanner/check-scanner-liveness.sh that uses fake_root.
    local stub_script="$BATS_TMPDIR/check-liveness-stub.sh"
    sed "s|LOOP_ROOT=.*|LOOP_ROOT='$fake_root'|" \
        "$REPO_ROOT/scanner/check-scanner-liveness.sh" > "$stub_script"
    chmod +x "$stub_script"
    run env LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
        LOOP_SCANNER_LIVENESS_THRESHOLD=600 \
        bash "$stub_script" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}
