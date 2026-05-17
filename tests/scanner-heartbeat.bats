#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. scanner.sh writes scanner-heartbeat at the start of every tick.
#   2. check-scanner-liveness.sh exits quietly when heartbeat is fresh.
#   3. check-scanner-liveness.sh kills a wedged PID when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Fake log dir so env.sh doesn't touch ~/.loop/logs.
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same awk strip as scanner.bats).
    export LOOP_EXTRA_PATH=""
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() and disable dispatch so run_once doesn't call gh.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat: written on every tick
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file on first tick" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: updates scanner-heartbeat mtime on subsequent ticks" {
    touch -t 200001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"
    local before
    before=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat")
    sleep 1
    run_once
    local after
    after=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
            || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat")
    [ "$after" -gt "$before" ]
}

@test "run_once: does NOT write heartbeat in dry-run mode" {
    DRY_RUN=true
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# check-scanner-liveness.sh: fresh heartbeat → no action
# ---------------------------------------------------------------------------

@test "check-scanner-liveness: exits 0 with fresh heartbeat" {
    touch "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_STALE_THRESHOLD=600 \
            "$REPO_ROOT/scripts/check-scanner-liveness.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is live"* ]]
}

# ---------------------------------------------------------------------------
# check-scanner-liveness.sh: stale heartbeat → kill wedged PID
# ---------------------------------------------------------------------------

@test "check-scanner-liveness: exits 0 even when heartbeat is stale (no live PID)" {
    # Simulate stale heartbeat by backdating the file.
    touch -t 200001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"
    # No lock file → watchdog should still exit cleanly.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_STALE_THRESHOLD=1 \
            "$REPO_ROOT/scripts/check-scanner-liveness.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "check-scanner-liveness: kills wedged PID when heartbeat is stale" {
    # Spawn a long-running background process to act as the fake wedged scanner.
    sleep 60 &
    local fake_pid=$!

    # Write its PID to the scanner lock file.
    echo "$fake_pid" > /tmp/loop-scanner.lock

    # Back-date the heartbeat to simulate a stale scanner.
    touch -t 200001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_STALE_THRESHOLD=1 \
            "$REPO_ROOT/scripts/check-scanner-liveness.sh"
    [ "$status" -eq 0 ]

    # Give SIGTERM a moment to land.
    sleep 1

    # The fake process should no longer be alive.
    ! kill -0 "$fake_pid" 2>/dev/null

    rm -f /tmp/loop-scanner.lock
}
