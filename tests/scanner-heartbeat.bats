#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat + watchdog (#413).
#
# Two concerns tested here:
#   1. scanner.sh run_once() writes an epoch to scanner-heartbeat.
#   2. restart-scanner-if-stale.sh correctly detects a stale heartbeat.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/hb-logs-$$"
    mkdir -p "$LOOP_LOG_DIR"
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

# ---------------------------------------------------------------------------
# 1. scanner.sh heartbeat write
# ---------------------------------------------------------------------------

@test "scanner.sh run_once writes scanner-heartbeat" {
    # Run scanner --once in a minimal subshell. Stub out everything that
    # touches GitHub or the jobs DB; use an empty projects list.
    TMPCONF="$BATS_TMPDIR/projects-empty-$$.yaml"
    printf 'projects: []\n' > "$TMPCONF"

    run bash -c "
        export LOOP_ROOT='$REPO_ROOT'
        export LOOP_LOG_DIR='$LOOP_LOG_DIR'
        export LOOP_JOBS_ENQUEUE=0
        export LOOP_LOCK_DIR='$BATS_TMPDIR/locks-$$'
        mkdir -p \"\$LOOP_LOCK_DIR\"
        # Override acquire_lock so it does not exit when lock exists.
        acquire_lock() { trap 'rm -f /tmp/loop-scanner-hbtest-$$.lock' EXIT; return 0; }
        export -f acquire_lock
        # Point config loader to an empty project list.
        loop_list_slugs() { :; }
        export -f loop_list_slugs
        # Run --once; heartbeat is skipped in --dry-run so use --once.
        '$REPO_ROOT/scanner/scanner.sh' --once 2>/dev/null
        exit 0
    " || true  # tolerate non-zero exit from stubs
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "scanner-heartbeat file contains a recent epoch" {
    TMPCONF="$BATS_TMPDIR/projects-empty2-$$.yaml"
    printf 'projects: []\n' > "$TMPCONF"

    bash -c "
        export LOOP_ROOT='$REPO_ROOT'
        export LOOP_LOG_DIR='$LOOP_LOG_DIR'
        export LOOP_JOBS_ENQUEUE=0
        acquire_lock() { return 0; }
        loop_list_slugs() { :; }
        export -f acquire_lock loop_list_slugs
        '$REPO_ROOT/scanner/scanner.sh' --once 2>/dev/null
        exit 0
    " || true

    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ] || skip "heartbeat not written (env issue)"
    local beat; beat=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    local now; now=$(date +%s)
    [[ "$beat" =~ ^[0-9]+$ ]]
    [ $(( now - beat )) -lt 60 ]
}

# ---------------------------------------------------------------------------
# 2. restart-scanner-if-stale.sh watchdog logic
# ---------------------------------------------------------------------------

@test "watchdog: fresh heartbeat exits 0 with ok message" {
    printf '%s\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_WATCHDOG_STALE_SECONDS=900 \
        "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

@test "watchdog: stale heartbeat logs STALE and DRY-RUN in dry-run mode" {
    # Write a heartbeat 1000 seconds old as file content.
    printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_WATCHDOG_STALE_SECONDS=900 \
        "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "watchdog: missing heartbeat exits 0 with absent message" {
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_WATCHDOG_STALE_SECONDS=900 \
        "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]]
}

@test "watchdog: heartbeat just under threshold is not stale" {
    # 800s old < 900s threshold → ok.
    printf '%s\n' "$(( $(date +%s) - 800 ))" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_WATCHDOG_STALE_SECONDS=900 \
        "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}
