#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written by scanner.sh (#413).
#
# Verifies:
#   1. run_once() writes HEARTBEAT_FILE on every tick (non-dry-run mode).
#   2. The heartbeat file contains a recent Unix timestamp.
#   3. run_once() does NOT write HEARTBEAT_FILE in dry-run mode.
#   4. restart-scanner-if-stale.sh exits 0 when heartbeat is fresh.
#   5. restart-scanner-if-stale.sh exits 0 when heartbeat file is absent.
#   6. restart-scanner-if-stale.sh removes a stale lock when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same technique as scanner.bats).
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

    # Override dynamic paths to use test-local dirs.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log output and stub out functions that would make real API calls.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    _budget_exceeded() { return 1; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" "$BATS_TMPDIR/stage-age" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file written by run_once()
# ---------------------------------------------------------------------------

@test "run_once: writes HEARTBEAT_FILE on every tick" {
    [ ! -f "$HEARTBEAT_FILE" ]  # precondition: file does not yet exist
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: HEARTBEAT_FILE contains a numeric Unix timestamp" {
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Must be all digits and roughly match now (within 60s).
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now delta
    now=$(date +%s)
    delta=$(( now - ts ))
    [ "$delta" -ge 0 ]
    [ "$delta" -lt 60 ]
}

@test "run_once: HEARTBEAT_FILE timestamp advances between ticks" {
    run_once
    local ts1
    ts1=$(cat "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "$HEARTBEAT_FILE")
    [ "$ts2" -ge "$ts1" ]
}

@test "run_once: does NOT write HEARTBEAT_FILE in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh watchdog
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale.sh: exits 0 when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "$HEARTBEAT_FILE"
    export LOOP_LOG_DIR
    export LOOP_EXTRA_PATH=""
    run bash "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "restart-scanner-if-stale.sh: exits 0 when heartbeat file is absent" {
    rm -f "$HEARTBEAT_FILE"
    export LOOP_LOG_DIR
    export LOOP_EXTRA_PATH=""
    run bash "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]]
}

@test "restart-scanner-if-stale.sh: detects stale heartbeat and removes dead lock" {
    printf '%s\n' "0" > "$HEARTBEAT_FILE"
    local fake_lock="/tmp/loop-scanner.lock"
    printf '999999\n' > "$fake_lock"
    export LOOP_LOG_DIR
    export LOOP_EXTRA_PATH=""
    export LOOP_SCANNER_WATCHDOG_STALE_SECONDS=1
    run bash "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN:"* ]]
    [ ! -f "$fake_lock" ]
}
