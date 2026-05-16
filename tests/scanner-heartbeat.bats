#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written on every tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner functions (same strategy as tests/scanner.bats).
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

    # Silence noisy helpers; prevent real dispatches.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once writes scanner-heartbeat file" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]   # not present before first tick
    run_once
    [ -f "$hb" ]
}

@test "run_once updates heartbeat on each call" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    local ts1
    ts1=$(cat "$hb")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "$hb")
    # Timestamps must be numeric and non-decreasing.
    [[ "$ts1" =~ ^[0-9]+$ ]]
    [[ "$ts2" =~ ^[0-9]+$ ]]
    [ "$ts2" -ge "$ts1" ]
}

@test "scanner-watchdog.sh exits 0 when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date +%s > "$hb"
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
}

@test "scanner-watchdog.sh exits 0 quietly when no heartbeat file" {
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
}

@test "scanner-watchdog.sh kills wedged scanner PID when heartbeat is stale" {
    # Spawn a long-lived background process to act as the mock scanner.
    sleep 60 &
    local mock_pid=$!

    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a stale timestamp (far in the past).
    echo "1" > "$hb"   # epoch 1 is always stale

    # Point lock file at our mock PID.
    echo "$mock_pid" > /tmp/loop-scanner.lock

    run bash -c "LOOP_LOG_DIR='$LOOP_LOG_DIR' LOOP_SCANNER_STALE_THRESHOLD=5 '$REPO_ROOT/scanner/scanner-watchdog.sh'"
    [ "$status" -eq 0 ]

    # Mock process should have been killed.
    sleep 0.2
    ! kill -0 "$mock_pid" 2>/dev/null

    rm -f /tmp/loop-scanner.lock
}
