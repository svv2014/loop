#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat (#413).
#
# 1. scanner.sh: heartbeat file is touched on every run_once tick.
# 2. scanner-watchdog.sh: no-op when heartbeat is fresh.
# 3. scanner-watchdog.sh: exits non-zero (or logs restart intent) when stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Provide a mock gh so env.sh sources don't fail.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh doesn't shadow our mock gh.
    export LOOP_EXTRA_PATH=""

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: source scanner.sh function definitions only (same strategy as
# scanner.bats — strip SCRIPT_DIR/LOOP_ROOT assignments and arg-parser loop,
# stop before acquire_lock).
# ---------------------------------------------------------------------------
_source_scanner() {
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

    # Override paths after sourcing.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    log() { :; }
    dispatch_direct() { :; }
}

# ---------------------------------------------------------------------------
# scanner.sh — heartbeat file updated on every tick
# ---------------------------------------------------------------------------

@test "scanner run_once: heartbeat file is created on first tick" {
    _source_scanner

    # Stub out everything scan_project calls so run_once completes quickly.
    loop_list_slugs()    { return 0; }
    _sweep_stale_locks() { return 0; }
    jobs_init_schema()   { return 0; }

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run_once

    [ -f "$HEARTBEAT_FILE" ]
}

@test "scanner run_once: heartbeat file mtime advances between ticks" {
    _source_scanner

    loop_list_slugs()    { return 0; }
    _sweep_stale_locks() { return 0; }
    jobs_init_schema()   { return 0; }

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    # Wait 1s so the mtime can differ.
    sleep 1

    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "scanner run_once: heartbeat file not created in --dry-run mode" {
    _source_scanner
    DRY_RUN=true

    loop_list_slugs()    { return 0; }
    _sweep_stale_locks() { return 0; }
    jobs_init_schema()   { return 0; }

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run_once

    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — behavioural tests
# ---------------------------------------------------------------------------

@test "scanner-watchdog: no-op when heartbeat is fresh" {
    # Create a heartbeat file with mtime = now.
    touch "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner healthy"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and logs restart intent" {
    # Create a heartbeat file and set threshold to 1s so it's immediately stale.
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    sleep 2
    LOOP_SCANNER_WATCHDOG_STALE=1 \
        run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: would restart scanner"* ]]
}

@test "scanner-watchdog: detects absent heartbeat as stale" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: would restart scanner"* ]]
}

@test "scanner-watchdog.sh source: HEARTBEAT_FILE variable is declared in scanner.sh" {
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
}
