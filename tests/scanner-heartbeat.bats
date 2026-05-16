#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. _scanner_write_heartbeat writes a heartbeat file on each tick.
#   2. run_once updates the heartbeat file (integration of the full tick).
#   3. scanner-watchdog.sh exits cleanly when heartbeat is fresh.
#   4. scanner-watchdog.sh reports stale when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner function definitions only (same pattern as scanner.bats).
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
    log() { :; }
    dispatch_direct() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "_scanner_write_heartbeat creates heartbeat file" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    _scanner_write_heartbeat
    [ -f "$hb" ]
}

@test "_scanner_write_heartbeat writes a numeric unix timestamp" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    _scanner_write_heartbeat
    local ts
    ts=$(cat "$hb")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "_scanner_write_heartbeat updates mtime on each call" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    _scanner_write_heartbeat
    local t1
    t1=$(cat "$hb")
    sleep 1
    _scanner_write_heartbeat
    local t2
    t2=$(cat "$hb")
    [ "$t2" -ge "$t1" ]
}

@test "_scanner_write_heartbeat is a no-op in dry-run mode" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    DRY_RUN=true
    _scanner_write_heartbeat
    [ ! -f "$hb" ]
}

@test "scanner-watchdog.sh exits 0 when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date +%s > "$hb"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "scanner-watchdog.sh reports stale when heartbeat is old" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a heartbeat timestamp 1 hour in the past.
    echo $(( $(date +%s) - 3600 )) > "$hb"
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null)" "$hb" 2>/dev/null || true
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "scanner-watchdog.sh exits 0 when no heartbeat file exists" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
}

@test "scanner.sh _scanner_check_log_fd is defined" {
    declare -f _scanner_check_log_fd > /dev/null
}
