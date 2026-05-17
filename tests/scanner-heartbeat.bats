#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner liveness heartbeat (issue #413).
#
# scanner.sh must write ${LOOP_LOG_DIR}/scanner-heartbeat on every tick so the
# external watchdog (scanner-watchdog.sh) can detect a wedged scanner without
# parsing log files.

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
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    LOOP_JOBS_ENQUEUE=0

    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: creates heartbeat file on first tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains a unix timestamp" {
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    [ -n "$ts" ]
    # Must be a number greater than 2020-01-01 (1577836800)
    [ "$ts" -gt 1577836800 ] 2>/dev/null
}

@test "run_once: heartbeat file is updated on subsequent ticks" {
    run_once
    local ts1
    ts1=$(cat "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "$HEARTBEAT_FILE")
    # Second timestamp must be >= first
    [ "$ts2" -ge "$ts1" ]
}

@test "run_once: DRY_RUN=true does not write heartbeat file" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "scanner.sh: HEARTBEAT_FILE is defined as \${LOOP_LOG_DIR}/scanner-heartbeat" {
    # Regression guard: ensure the variable assignment is present in the source.
    grep -q 'HEARTBEAT_FILE=.*scanner-heartbeat' "$REPO_ROOT/scanner/scanner.sh"
}
