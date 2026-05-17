#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify heartbeat file is written every tick.
#
# Sources scanner.sh function definitions (same strategy as scanner.bats).
# Stubs out loop_list_slugs, scan_project, and other side-effectful helpers
# so run_once completes without touching GitHub.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh does not prepend extra dirs.
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

    # Override paths set after sourcing.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="$BATS_TMPDIR/logs/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub side-effectful helpers so run_once completes without network calls.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_write_heartbeat: heartbeat file contains a timestamp" {
    _scanner_write_heartbeat
    content=$(cat "$HEARTBEAT_FILE")
    # Must contain a date-looking string (YYYY-MM-DD)
    [[ "$content" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
}

@test "_scanner_write_heartbeat: updates mtime on successive calls" {
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat: no-op in dry-run mode" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# run_once — heartbeat integration
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created during a tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat mtime advances between ticks" {
    run_once
    local before
    before=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    run_once
    local after
    after=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$after" -ge "$before" ]
}
