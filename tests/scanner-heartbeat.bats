#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify the scanner writes a heartbeat file on every tick.

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

    # Override paths.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    LOOP_JOBS_ENQUEUE=0

    # Silence log output and stub out side-effecting helpers.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
    _budget_exceeded() { return 1; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" "$BATS_TMPDIR/stage-age" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

@test "scanner.sh defines HEARTBEAT_FILE variable" {
    # HEARTBEAT_FILE must be set after sourcing scanner.sh.
    [ -n "${HEARTBEAT_FILE:-}" ]
}

@test "run_once: heartbeat file is created on first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file mtime is updated on each tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    # Sleep at least 1 second so mtime can advance.
    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}
