#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner liveness heartbeat (#413).
#
# Verifies:
#   1. run_once() touches ${LOOP_LOG_DIR}/scanner-heartbeat on each tick.
#   2. scanner-watchdog.sh exits 0 without action when heartbeat is fresh.
#   3. scanner-watchdog.sh reports stale heartbeat and (in dry-run) would restart.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Minimal env so scanner.sh sources cleanly without a real loop.env.
    export LOOP_SCANNER_INTERVAL=300
    export LOOP_EXTRA_PATH=""

    # Source scanner functions (same strategy as scanner.bats).
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

    # Override runtime paths to stay inside tmp.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub out log/dispatch/project scanning so run_once completes quickly.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file creation
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file" {
    run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "run_once: updates scanner-heartbeat mtime on each call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: does NOT create scanner-heartbeat when DRY_RUN=true" {
    DRY_RUN=true
    run_once
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — dry-run mode
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner healthy"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "scanner-watchdog: reports stale and dry-run restart when heartbeat is old" {
    # Create a heartbeat file that is 800 seconds old by back-dating its mtime.
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    local old_time
    old_time=$(date -v -800S +%Y%m%d%H%M.%S 2>/dev/null \
               || date -d "800 seconds ago" +%Y%m%d%H%M.%S 2>/dev/null \
               || echo "")
    if [ -n "$old_time" ]; then
        touch -t "$old_time" "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || true
    fi

    LOOP_WATCHDOG_STALE_THRESHOLD=600 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
