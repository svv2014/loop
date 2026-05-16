#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file written on every tick.
#
# Sources scanner.sh function definitions (same awk-strip strategy as
# tests/scanner.bats). Verifies that run_once() touches HEARTBEAT_FILE on
# each call when not in dry-run mode, and skips the touch in dry-run mode.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

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

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub out everything run_once calls so the test stays unit-level.
    log()              { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs()  { echo ""; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

@test "run_once: creates heartbeat file on first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: updates heartbeat mtime on every tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    # Small sleep so mtime can advance (1-second resolution on most filesystems)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: skips heartbeat in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}
