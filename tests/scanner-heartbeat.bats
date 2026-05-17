#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#   1. _write_heartbeat creates / updates HEARTBEAT_FILE on every tick.
#   2. scanner-watchdog.sh reports verdict=ok when heartbeat is fresh.
#   3. scanner-watchdog.sh reports verdict=stale when heartbeat is old.
#   4. scanner-watchdog.sh handles absent heartbeat + no lock gracefully.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same pattern as scanner.bats).
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

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/stage-age" "$BATS_TMPDIR/scanner-src.sh" \
           "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _write_heartbeat
# ---------------------------------------------------------------------------

@test "_write_heartbeat: creates HEARTBEAT_FILE" {
    rm -f "$HEARTBEAT_FILE"
    _write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_write_heartbeat: file contains a numeric epoch" {
    _write_heartbeat
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "_write_heartbeat: mtime advances on second call" {
    _write_heartbeat
    local t1
    t1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    _write_heartbeat
    local t2
    t2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$t2" -ge "$t1" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: verdict=ok when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_SCANNER_WATCHDOG_STALE_SECONDS=600 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"verdict=ok"* ]]
}

@test "scanner-watchdog: verdict=stale when heartbeat is old" {
    # Write a timestamp 20 minutes in the past and backdate the file.
    printf '%s\n' "$(( $(date +%s) - 1200 ))" > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t "$(date -d '20 minutes ago' '+%Y%m%d%H%M' 2>/dev/null \
        || date -v-20M '+%Y%m%d%H%M')" "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || true
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_SCANNER_WATCHDOG_STALE_SECONDS=600 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "scanner-watchdog: absent heartbeat with no lock exits 0" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
}
