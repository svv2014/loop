#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner liveness heartbeat (#413).
# Verifies that run_once() writes the heartbeat file on every tick and that
# DRY_RUN suppresses the write.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export DEDUP_DIR="$BATS_TMPDIR/dedup"
    mkdir -p "$DEDUP_DIR"

    # Extract scanner.sh definitions up to acquire_lock, same pattern as scanner.bats.
    local _src="$BATS_TMPDIR/scanner-hb-src.sh"
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

    # Stub out functions that require live network or config.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
    DRY_RUN=false
    LOG_FILE="$BATS_TMPDIR/scanner.log"
    touch "$LOG_FILE"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-hb-src.sh" "$BATS_TMPDIR/scanner.log" 2>/dev/null || true
}

@test "scanner.sh: heartbeat write is present in source" {
    grep -q "scanner-heartbeat" "$REPO_ROOT/scanner/scanner.sh"
}

@test "run_once: creates heartbeat file in LOOP_LOG_DIR" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "run_once: heartbeat file contains a Unix epoch integer" {
    run_once
    local val
    val=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [[ "$val" =~ ^[0-9]+$ ]]
    [ "$val" -gt 0 ]
}

@test "run_once: heartbeat timestamp is non-decreasing across ticks" {
    run_once
    local ts1
    ts1=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [ "$ts2" -ge "$ts1" ]
}

@test "run_once: DRY_RUN=true does not write heartbeat file" {
    DRY_RUN=true
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ ! -f "$hb" ]
}
