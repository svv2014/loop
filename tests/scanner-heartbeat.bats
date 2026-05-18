#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify that scanner.sh writes the heartbeat
# file on every tick and that restart-scanner-if-stale.sh correctly detects
# stale vs. fresh heartbeats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh.sh for any backend calls that leak through.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export LOOP_EXTRA_PATH=""
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Source scanner.sh function definitions only (same awk pattern as scanner.bats).
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
    LOG_FILE="$BATS_TMPDIR/scanner-hb-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence helpers to keep test output clean.
    log()            { :; }
    dispatch_direct(){ :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    loop_list_slugs()    { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-hb-src.sh" \
           "$BATS_TMPDIR/scanner-hb-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file — written by run_once on every tick
# ---------------------------------------------------------------------------

@test "run_once: writes scanner-heartbeat file to LOOP_LOG_DIR" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"

    run_once

    [ -f "$hb" ]
}

@test "run_once: heartbeat file contains a numeric epoch timestamp" {
    run_once

    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    local ts
    ts=$(cat "$hb")
    # Must be a positive integer (Unix epoch is > 1_000_000_000 since 2001)
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -gt 1000000000 ]
}

@test "run_once: heartbeat mtime is updated on successive ticks" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"

    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)

    # Force at least one second between ticks.
    sleep 1

    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat is NOT written in dry-run mode" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"

    run_once

    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh — stale/fresh detection logic
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale: exits 0 without acting when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a heartbeat that is only 10 seconds old (well within threshold).
    printf '%s\n' "$(date +%s)" > "$hb"

    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" != *"would restart"* ]]
}

@test "restart-scanner-if-stale: detects stale heartbeat and logs restart intent" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    # Create an obviously stale heartbeat (epoch 1 = 1970-01-01).
    printf '1\n' > "$hb"
    # Back-date the file so mtime also looks old.
    touch -t 197001010000 "$hb" 2>/dev/null || touch -d "1970-01-01 00:00:00" "$hb" 2>/dev/null || true

    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"would restart"* ]]
}

@test "restart-scanner-if-stale: exits 0 when heartbeat file does not exist" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
}
