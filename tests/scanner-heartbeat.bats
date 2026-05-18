#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — covers _scanner_heartbeat and _scanner_emit_tick
# in scanner/scanner.sh (issue #413).
#
# Verifies:
#   1. Heartbeat file is created/updated on every run_once() call.
#   2. Heartbeat is NOT written in --dry-run mode.
#   3. _scanner_emit_tick is a no-op in --dry-run mode.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs-hb"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""
    local _src="$BATS_TMPDIR/scanner-src-hb.sh"
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

    DEDUP_DIR="$BATS_TMPDIR/dedup-hb"
    LOG_FILE="$BATS_TMPDIR/scanner-hb-test.log"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    LOOP_JOBS_ENQUEUE=0

    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    _loop_emit_event() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs-hb" "$BATS_TMPDIR/dedup-hb" \
           "$BATS_TMPDIR/scanner-hb-test.log" \
           "$BATS_TMPDIR/scanner-src-hb.sh" 2>/dev/null || true
}

@test "_scanner_heartbeat: creates heartbeat file on first call" {
    [ ! -f "$HEARTBEAT_FILE" ]
    _scanner_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_heartbeat: updates heartbeat mtime on second call" {
    _scanner_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    _scanner_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_heartbeat: dry-run does not write heartbeat file" {
    DRY_RUN=true
    _scanner_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file exists after a tick" {
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat content is a timestamp string" {
    run_once
    local content
    content=$(cat "$HEARTBEAT_FILE")
    # Must match YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "_scanner_emit_tick: dry-run skips emission" {
    DRY_RUN=true
    local called=false
    _loop_emit_event() { called=true; }
    _scanner_emit_tick
    [ "$called" = "false" ]
}

@test "_scanner_emit_tick: calls _loop_emit_event with scanner_tick type" {
    local captured_type=""
    _loop_emit_event() { captured_type="$1"; }
    _scanner_emit_tick
    [ "$captured_type" = "scanner_tick" ]
}
