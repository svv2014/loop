#!/usr/bin/env bats
# tests/scanner-watchdog.bats — heartbeat + watchdog coverage for #413.
#
# Tests:
#   1. scanner run_once() touches HEARTBEAT_FILE on every tick (non-dry-run)
#   2. scanner run_once() skips HEARTBEAT_FILE in dry-run mode
#   3. scanner run_once() updates heartbeat mtime on repeated calls
#   4. scanner-watchdog.sh exits 0 when heartbeat is fresh
#   5. scanner-watchdog.sh detects missing heartbeat file as stale
#   6. scanner-watchdog.sh detects old heartbeat mtime as stale
#   7. scanner-watchdog.sh dry-run emits DRY-RUN message without killing

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh does not shadow the mock gh binary.
    export LOOP_EXTRA_PATH=""

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/dedup" 2>/dev/null || true
}

# Source scanner.sh function definitions only (same awk filter as scanner.bats).
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    mkdir -p "$DEDUP_DIR"

    # Silence output; no-op dispatch
    log() { :; }
    dispatch_direct() { :; }
}

# ---------------------------------------------------------------------------
# Heartbeat: run_once() touches HEARTBEAT_FILE on every tick
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created on each tick" {
    _source_scanner

    local log_file="$LOOP_LOG_DIR/loop-scanner.log"
    touch "$log_file"
    LOG_FILE="$log_file"

    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    HEARTBEAT_FILE="$heartbeat"
    rm -f "$heartbeat"

    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }

    run_once

    [ -f "$heartbeat" ]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    _source_scanner
    DRY_RUN=true

    local log_file="$LOOP_LOG_DIR/loop-scanner.log"
    touch "$log_file"
    LOG_FILE="$log_file"

    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    HEARTBEAT_FILE="$heartbeat"
    rm -f "$heartbeat"

    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }

    run_once

    [ ! -f "$heartbeat" ]
}

@test "run_once: heartbeat mtime advances on second call" {
    # Requires cross-platform stat — skip gracefully if neither form works.
    local probe
    probe=$(stat -f%m "$BATS_TMPDIR" 2>/dev/null || stat -c%Y "$BATS_TMPDIR" 2>/dev/null || true)
    [ -n "$probe" ] || skip "stat mtime not available on this platform"

    _source_scanner

    local log_file="$LOOP_LOG_DIR/loop-scanner.log"
    touch "$log_file"
    LOG_FILE="$log_file"

    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    HEARTBEAT_FILE="$heartbeat"

    # Pre-seed an old heartbeat.
    touch -t 200001010000 "$heartbeat"
    local old_mtime
    old_mtime=$(stat -f%m "$heartbeat" 2>/dev/null || stat -c%Y "$heartbeat" 2>/dev/null)

    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }

    run_once

    local new_mtime
    new_mtime=$(stat -f%m "$heartbeat" 2>/dev/null || stat -c%Y "$heartbeat" 2>/dev/null)
    [ "$new_mtime" -gt "$old_mtime" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: heartbeat freshness and stale detection
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 and reports fresh when heartbeat just written" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fresh"* ]]
}

@test "scanner-watchdog: detects missing heartbeat file as stale" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]] || [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog: detects old heartbeat as stale" {
    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$heartbeat"
    export LOOP_SCANNER_WATCHDOG_STALE=60
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog: dry-run emits DRY-RUN and does not kill" {
    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$heartbeat"
    export LOOP_SCANNER_WATCHDOG_STALE=60
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
}
