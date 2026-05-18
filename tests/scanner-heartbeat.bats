#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner heartbeat (#413).
# Verifies that run_once() writes the heartbeat file on every tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export DEDUP_DIR="$BATS_TMPDIR/dedup"
    mkdir -p "$DEDUP_DIR"

    # Extract scanner.sh up to (but not including) acquire_lock, injecting
    # LOOP_ROOT and stripping the arg-parsing block (same pattern as scanner.bats).
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

    # Silence log output; stub out functions that require live network/config.
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

@test "scanner.sh: heartbeat code is present in source" {
    grep -q "scanner-heartbeat" "$REPO_ROOT/scanner/scanner.sh"
}

@test "run_once: creates heartbeat file in LOOP_LOG_DIR" {
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb_file" ]          # not present before the tick
    run_once
    [ -f "$hb_file" ]            # created after the tick
}

@test "run_once: heartbeat file contains a Unix epoch timestamp" {
    run_once
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    local val
    val=$(cat "$hb_file")
    # Must be a positive integer (epoch seconds, currently 10 digits)
    [[ "$val" =~ ^[0-9]+$ ]]
    [ "$val" -gt 0 ]
}

@test "run_once: heartbeat file is updated on each tick" {
    run_once
    local ts1
    ts1=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")

    # Sleep briefly so the epoch advances, then run a second tick.
    sleep 1
    run_once
    local ts2
    ts2=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")

    [ "$ts2" -ge "$ts1" ]
}

@test "run_once: DRY_RUN=true does not write heartbeat file" {
    DRY_RUN=true
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb_file" ]
    run_once
    [ ! -f "$hb_file" ]
}
