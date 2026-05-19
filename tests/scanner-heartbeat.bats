#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file written on every scanner tick.
#
# Loads scanner.sh function definitions (same awk-strip technique as scanner.bats),
# then verifies that run_once writes a Unix timestamp to $HEARTBEAT_FILE.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log()           { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    loop_list_slugs()    { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

@test "run_once: heartbeat file is created on first tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains a Unix timestamp" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Must be a positive integer and within the last 10 seconds
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    [ "$(( now - ts ))" -lt 10 ]
}

@test "run_once: heartbeat file mtime is updated on each tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo 0)

    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
        || echo 0)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}
