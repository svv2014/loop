#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify heartbeat file is updated on every tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same awk extraction as scanner.bats).
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

    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-hb-test.log"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log()              { :; }
    dispatch_direct()  { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    loop_list_slugs()    { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-hb-src.sh" \
           "$BATS_TMPDIR/scanner-hb-test.log" 2>/dev/null || true
}

@test "_scanner_write_heartbeat: creates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_write_heartbeat: updates mtime on each call" {
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat: writes a non-empty timestamp" {
    _scanner_write_heartbeat
    [ -s "$HEARTBEAT_FILE" ]
    local content
    content=$(cat "$HEARTBEAT_FILE")
    [ -n "$content" ]
}

@test "_scanner_write_heartbeat: is a no-op in dry-run mode" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file is written during each tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file content is a timestamp" {
    run_once
    local content
    content=$(cat "$HEARTBEAT_FILE")
    # Matches YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "_scanner_check_stdout: no-op when LOG_FILE is writable" {
    # Should succeed without error when file exists and is writable.
    run _scanner_check_stdout
    [ "$status" -eq 0 ]
}

@test "_scanner_check_stdout: no-op when LOG_FILE is unset" {
    local saved="$LOG_FILE"
    LOG_FILE=""
    run _scanner_check_stdout
    LOG_FILE="$saved"
    [ "$status" -eq 0 ]
}
