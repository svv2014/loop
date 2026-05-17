#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner liveness heartbeat (#413).
#
# run_once() must touch ${LOOP_LOG_DIR}/scanner-heartbeat on every tick so
# the scanner-watchdog can detect a wedged process by mtime.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Minimal mock-gh so env.sh / config.sh do not fail.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Extract function definitions from scanner.sh up to (but not including)
    # the bare acquire_lock call. Same awk pattern as tests/scanner.bats.
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

    # Override dirs so the test is fully isolated.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub out everything that would hit GitHub or run handlers.
    log()             { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { printf ''; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" "$BATS_TMPDIR/stage-age" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: creates heartbeat file on first tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "run_once: updates heartbeat mtime on each call" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat not written in dry-run mode" {
    DRY_RUN=true
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    [ ! -f "$hb" ]
}
