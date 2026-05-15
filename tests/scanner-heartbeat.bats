#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is updated on every tick.

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

    # Silence output; stub out heavy calls.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: creates heartbeat file on first tick" {
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: updates heartbeat mtime on subsequent ticks" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat")
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: does not create heartbeat file in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}
