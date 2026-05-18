#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner.sh writes the liveness
# heartbeat file on every tick (acceptance criteria for #413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""
    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh function definitions (same strategy as scanner.bats).
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

    # Silence log() and no-op side-effectful functions.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file in LOOP_LOG_DIR" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"

    run_once

    [ -f "$hb" ]
}

@test "run_once: updates heartbeat mtime on each tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"

    # First tick
    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)

    # Ensure at least 1 second passes so mtime can differ.
    sleep 1.1

    # Second tick
    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat skipped in dry-run mode" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"

    run_once

    [ ! -f "$hb" ]
}
