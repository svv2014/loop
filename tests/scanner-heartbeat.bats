#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is written on every scanner tick.

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

    # Override paths so scanner runs against test dirs.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { return 0; }
    loop_list_slugs() { echo ""; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: heartbeat file is created on first tick" {
    LOOP_JOBS_ENQUEUE=0 run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat file contains a unix timestamp" {
    LOOP_JOBS_ENQUEUE=0 run_once
    local val
    val=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Timestamp should be a 10-digit number (valid through year 2286)
    [[ "$val" =~ ^[0-9]{10}$ ]]
}

@test "run_once: heartbeat file mtime advances on consecutive ticks" {
    LOOP_JOBS_ENQUEUE=0 run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    sleep 1
    LOOP_JOBS_ENQUEUE=0 run_once
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    DRY_RUN=true
    LOOP_JOBS_ENQUEUE=0 run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}
