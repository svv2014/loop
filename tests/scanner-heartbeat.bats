#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verifies scanner writes heartbeat on every tick (#413).

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

    # Stub out everything that touches GitHub or dispatches.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: creates heartbeat file on first tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ -f "$hb" ]
}

@test "run_once: heartbeat mtime is updated on each tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    # Create a stale heartbeat (1 hour ago via backdated touch on macOS/Linux).
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$hb" 2>/dev/null \
        || touch "$hb"
    local before_mtime
    before_mtime=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)

    sleep 1
    run_once

    local after_mtime
    after_mtime=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    [ "$after_mtime" -gt "$before_mtime" ]
}

@test "run_once: heartbeat not written in dry-run mode" {
    DRY_RUN=true
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ ! -f "$hb" ]
}
