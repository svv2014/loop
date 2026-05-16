#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes heartbeat on every tick (#413).

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

    # Minimal stubs so run_once does not attempt real GitHub calls.
    loop_list_slugs()  { echo "test-slug"; }
    scan_project()     { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: heartbeat file is created on first tick" {
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat file mtime is updated on each tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)

    # Ensure at least one second elapses so mtime changes.
    sleep 1.1

    run_once
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)

    [ "$mtime2" -gt "$mtime1" ]
}

@test "run_once: heartbeat file contains a timestamp line" {
    run_once
    local content
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Matches YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}
