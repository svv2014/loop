#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes heartbeat file every tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

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
    export PATH="$BATS_TMPDIR/bin:$PATH"

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: heartbeat file is created on first tick" {
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb_file" ]
    run_once
    [ -f "$hb_file" ]
}

@test "run_once: heartbeat file contains a unix timestamp" {
    run_once
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    local ts
    ts=$(cat "$hb_file")
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -gt 1000000000 ]
}

@test "run_once: heartbeat file mtime is updated on each tick" {
    run_once
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    local mtime1
    mtime1=$(stat -f%m "$hb_file" 2>/dev/null || stat -c%Y "$hb_file" 2>/dev/null)

    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "$hb_file" 2>/dev/null || stat -c%Y "$hb_file" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    DRY_RUN=true
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    [ ! -f "$hb_file" ]
}
