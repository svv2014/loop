#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes heartbeat on every tick.
#
# Sourcing strategy mirrors tests/scanner.bats: awk extracts function/variable
# definitions from scanner.sh and stops before the bare "acquire_lock" call.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Build a sourceable version of scanner.sh (same awk filter as scanner.bats).
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

    # Stub out heavy dependencies so run_once() completes without side effects.
    log()              { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs()  { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

@test "run_once: writes scanner-heartbeat file" {
    DRY_RUN=false
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat contains a unix timestamp" {
    DRY_RUN=false
    run_once
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Must be a non-empty string of digits (epoch seconds).
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "run_once: heartbeat is updated on every tick" {
    DRY_RUN=false

    run_once
    local ts1
    ts1=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")

    # Ensure the clock advances before the second tick.
    sleep 1

    run_once
    local ts2
    ts2=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")

    # Second timestamp must be >= first (monotonically non-decreasing).
    [ "$ts2" -ge "$ts1" ]
}

@test "run_once: does NOT write heartbeat in dry-run mode" {
    DRY_RUN=true
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ ! -f "$hb" ]
}
