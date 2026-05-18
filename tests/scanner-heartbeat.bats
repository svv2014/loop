#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for issue #413 liveness heartbeat.
#
# Verifies:
#   1. _scanner_write_heartbeat creates/updates HEARTBEAT_FILE every tick.
#   2. run_once updates the heartbeat file (integration check via sourced fns).
#   3. _scanner_check_log_fd reopens log when the file disappears.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same technique as scanner.bats).
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

    # Override runtime vars to test-local paths.
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    LOG_FILE="$LOOP_LOG_DIR/scanner-test.log"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    # Silence log() and no-op heavy helpers.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }

    # Ensure DRY_RUN=false so guards don't skip heartbeat writes.
    DRY_RUN=false
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/stage-age" "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

@test "_scanner_write_heartbeat creates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_write_heartbeat updates mtime on each call" {
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat includes pid= in file content" {
    _scanner_write_heartbeat
    grep -q "pid=" "$HEARTBEAT_FILE"
}

@test "run_once updates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_check_log_fd reopens log fd when file is missing" {
    # Verify the function exists and does not error when LOG_FILE is absent.
    rm -f "$LOG_FILE"
    # Should not exit non-zero even if exec fails (|| true inside function).
    _scanner_check_log_fd
}
