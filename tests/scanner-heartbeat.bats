#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that _scanner_write_heartbeat updates the heartbeat file on every
# tick, and that restart-scanner-if-stale.sh correctly detects a fresh vs
# stale heartbeat.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh does not shadow mock binaries.
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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

    # Override paths set after sourcing.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    HEARTBEAT_FILE="$BATS_TMPDIR/logs/scanner-heartbeat"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file when absent" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_write_heartbeat: heartbeat file contains PID and epoch" {
    _scanner_write_heartbeat
    local content
    content=$(cat "$HEARTBEAT_FILE")
    # Format: "<pid> <epoch> <dedup_count>"
    [[ "$content" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]
}

@test "_scanner_write_heartbeat: updates mtime on every call" {
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    # Sleep 1s so the mtime can advance.
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat: records current dedup_count in heartbeat" {
    # Plant two files in the dedup dir to simulate prior emits.
    touch "$DEDUP_DIR/aaaa" "$DEDUP_DIR/bbbb"
    _scanner_write_heartbeat
    local count_in_file
    count_in_file=$(awk '{print $3}' "$HEARTBEAT_FILE")
    [ "$count_in_file" -eq 2 ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh (dry-run mode)
# ---------------------------------------------------------------------------

@test "watchdog --dry-run: exits 0 and reports OK when heartbeat is fresh" {
    # Write a fresh heartbeat.
    printf '%s %s 0\n' "$$" "$(date +%s)" > "$HEARTBEAT_FILE"
    # Export LOOP_LOG_DIR so the watchdog script finds the heartbeat file.
    LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
    LOOP_SCANNER_INTERVAL=300 \
    run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "watchdog --dry-run: exits 0 and reports STALE when heartbeat is old" {
    # Write a heartbeat with a timestamp 20 minutes in the past.
    local old_epoch
    old_epoch=$(( $(date +%s) - 1200 ))
    printf '%s %s 0\n' "$$" "$old_epoch" > "$HEARTBEAT_FILE"
    # Manually set mtime to match (touch -t or via a Python one-liner).
    python3 -c "import os, time; os.utime('$HEARTBEAT_FILE', (time.time()-1200, time.time()-1200))" 2>/dev/null \
        || touch -t "$(date -v-20M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '20 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" \
           "$HEARTBEAT_FILE" 2>/dev/null || true
    LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
    LOOP_SCANNER_INTERVAL=300 \
    run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE:"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "watchdog --dry-run: treats absent heartbeat file as stale" {
    rm -f "$HEARTBEAT_FILE"
    LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
    LOOP_SCANNER_INTERVAL=300 \
    run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE:"* ]]
}
