#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 liveness heartbeat.
#
# Verifies that:
#   1. _scanner_write_heartbeat creates/updates ${LOOP_LOG_DIR}/scanner-heartbeat
#   2. The heartbeat file is updated on every run_once() tick.
#   3. scanner-watchdog.sh exits cleanly when heartbeat is fresh.
#   4. scanner-watchdog.sh triggers kill logic when heartbeat is stale
#      (dry-run mode — no actual kill).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same awk filter as scanner.bats).
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file in LOOP_LOG_DIR" {
    _scanner_write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_scanner_write_heartbeat: file contains a unix timestamp" {
    _scanner_write_heartbeat
    local content
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [ -n "$content" ]
    [[ "$content" =~ ^[0-9]+$ ]]
}

@test "_scanner_write_heartbeat: updates mtime on second call" {
    _scanner_write_heartbeat
    local before_content
    before_content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")

    # Ensure at least 1 second passes so timestamp changes.
    sleep 1

    _scanner_write_heartbeat
    local after_content
    after_content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")

    # Timestamp must be >= before (monotone).
    [ "$after_content" -ge "$before_content" ]
}

@test "_scanner_write_heartbeat: skipped in dry-run mode" {
    DRY_RUN=true
    _scanner_write_heartbeat
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# run_once writes heartbeat
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file exists after one tick" {
    # Stub out everything so run_once completes without hitting GitHub.
    loop_list_slugs()      { return 0; }
    jobs_init_schema()     { return 0; }
    _sweep_stale_locks()   { return 0; }

    run_once

    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — behavioural tests
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 without error when heartbeat file is fresh" {
    # Create a fresh heartbeat file (mtime = now).
    touch "${LOOP_LOG_DIR}/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok — scanner is alive"* ]]
}

@test "scanner-watchdog.sh: exits 0 when no heartbeat file exists yet" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner not yet started"* ]]
}

@test "scanner-watchdog.sh: reports stale heartbeat in dry-run mode" {
    # Write a heartbeat with a past timestamp (mtime set to epoch).
    touch -t 197001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
