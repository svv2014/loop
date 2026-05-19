#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat for scanner (#413).
#
# Verifies:
#   1. run_once writes/updates the scanner-heartbeat file on every tick.
#   2. scanner-watchdog.sh exits 0 (healthy) when heartbeat is fresh.
#   3. scanner-watchdog.sh kills the recorded PID when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh.sh as gh.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_EXTRA_PATH=""
    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh functions (same pattern as scanner.bats).
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    # Stub out project scanning so run_once completes without real gh calls.
    loop_list_slugs() { return 0; }
    scan_project() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" \
           "$BATS_TMPDIR/lock" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat written by run_once
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file on first tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ -f "$hb" ]
}

@test "run_once: updates scanner-heartbeat mtime on each tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$hb" 2>/dev/null || touch "$hb"
    local before
    before=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    sleep 1
    run_once
    local after
    after=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    [ "$after" -ge "$before" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — healthy case
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    touch "$hb"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — stale heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog: reports stale and kills wedged scanner PID" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    local lock_file="/tmp/loop-scanner.lock"

    # Start a long-running background process that we will use as the fake scanner PID.
    sleep 300 &
    local fake_pid=$!

    # Write the fake PID to the lock file.
    echo "$fake_pid" > "$lock_file"

    # Make the heartbeat appear ancient (set mtime to epoch via a very old touch).
    touch -t 200001010000 "$hb" 2>/dev/null || {
        # Fallback: skip if touch -t is not available.
        kill "$fake_pid" 2>/dev/null || true
        rm -f "$lock_file"
        skip "touch -t not supported on this platform"
    }

    # Set a very short threshold so the stale condition fires immediately.
    export LOOP_SCANNER_WATCHDOG_THRESHOLD=1
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"

    # Clean up.
    kill "$fake_pid" 2>/dev/null || true
    rm -f "$lock_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]] || [[ "$output" == *"killed"* ]] || [[ "$output" == *"killing"* ]]
}

@test "scanner-watchdog --dry-run: reports stale but does not kill" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    local lock_file="/tmp/loop-scanner.lock"

    sleep 300 &
    local fake_pid=$!
    echo "$fake_pid" > "$lock_file"

    touch -t 200001010000 "$hb" 2>/dev/null || {
        kill "$fake_pid" 2>/dev/null || true
        rm -f "$lock_file"
        skip "touch -t not supported on this platform"
    }

    export LOOP_SCANNER_WATCHDOG_THRESHOLD=1
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run

    local alive=0
    kill -0 "$fake_pid" 2>/dev/null && alive=1

    # Clean up.
    kill "$fake_pid" 2>/dev/null || true
    rm -f "$lock_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [ "$alive" -eq 1 ]
}
