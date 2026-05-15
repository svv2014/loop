#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. scanner.sh writes HEARTBEAT_FILE at the top of every run_once() tick.
#   2. restart-scanner-if-stale.sh exits 0 (OK) when heartbeat is fresh.
#   3. restart-scanner-if-stale.sh detects a stale / missing heartbeat in dry-run.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Set up isolated log dir.
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh doesn't prepend brew paths.
    export LOOP_EXTRA_PATH=""

    # Source scanner function definitions (same awk extraction as scanner.bats).
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

    # Override paths.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    # Silence log() and no-op dispatch_direct so run_once doesn't actually scan.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { printf ''; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "scanner.sh: HEARTBEAT_FILE variable is set in scanner source" {
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh: run_once writes heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "scanner.sh: heartbeat file contains a unix timestamp" {
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Timestamp must be numeric and greater than 1700000000 (year 2023+).
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -gt 1700000000 ]
}

@test "scanner.sh: run_once updates heartbeat on repeated calls" {
    run_once
    local first
    first=$(cat "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local second
    second=$(cat "$HEARTBEAT_FILE")
    [ "$second" -ge "$first" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale.sh: exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat.
    date '+%s' > "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "restart-scanner-if-stale.sh: detects missing heartbeat in dry-run" {
    rm -f "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN:"* ]]
    [[ "$output" == *"DRY-RUN:"* ]]
}

@test "restart-scanner-if-stale.sh: detects stale heartbeat in dry-run" {
    # Write a fresh heartbeat but set threshold to 1s so it appears stale immediately.
    date '+%s' > "$HEARTBEAT_FILE"
    sleep 2
    LOOP_SCANNER_STALE_THRESHOLD=1 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN:"* ]]
}
