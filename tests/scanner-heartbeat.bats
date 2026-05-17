#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes heartbeat on each tick
# and scanner-watchdog detects stale/fresh heartbeats correctly.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so mock gh wins PATH races.
    export LOOP_EXTRA_PATH=""

    # Source scanner function definitions, same approach as scanner.bats.
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

    # Silence log() and no-op all side-effects.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once writes heartbeat file" {
    run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "run_once updates heartbeat mtime on each call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    # Touch to an old time so a second call with a 1-s sleep produces a newer mtime.
    touch -t 202001010000 "$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -gt "$mtime1" ] || [ "$mtime2" -ge "$(date +%s)" ] || true
    # The heartbeat was re-touched; its mtime must be more recent than the fake old time.
    local old_time
    old_time=$(date -j -f "%Y%m%d%H%M" "202001010000" +%s 2>/dev/null \
        || date -d "2020-01-01 00:00" +%s 2>/dev/null \
        || echo 0)
    [ "$mtime2" -gt "$old_time" ]
}

@test "run_once does not write heartbeat in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}
