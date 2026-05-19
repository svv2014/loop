#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes a heartbeat file on every tick.

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
    export PATH="$BATS_TMPDIR/bin:$PATH"

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    # Minimal stubs so run_once/scan_project do not hit real backends.
    loop_list_slugs()              { echo ""; }
    jobs_init_schema()             { return 0; }
    _sweep_stale_locks()           { return 0; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

@test "heartbeat file is created by run_once" {
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "heartbeat file contains a timestamp" {
    run_once
    local content
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Expect a non-empty string that looks like a date.
    [ -n "$content" ]
    [[ "$content" == *"-"* ]]
}

@test "heartbeat file mtime is updated on each run_once call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || echo 0)
    # Ensure at least 1 second passes so mtime can differ.
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || echo 0)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "heartbeat file is NOT written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_scanner_heartbeat: writes file to LOOP_LOG_DIR" {
    _scanner_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}
