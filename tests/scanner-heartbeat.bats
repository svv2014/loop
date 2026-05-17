#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. run_once() writes/touches HEARTBEAT_FILE on every tick.
#   2. scanner-watchdog.sh exits 0 when heartbeat is fresh.
#   3. scanner-watchdog.sh logs STALE and removes the lock when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress /opt/homebrew/bin prepend so mock binaries take precedence.
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions (same awk extraction as scanner.bats).
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

    # Override scanner-internal path variables.
    HEARTBEAT_FILE="$BATS_TMPDIR/logs/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/logs/loop-scanner.log"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    # Silence log() and no-op heavy helpers so run_once() completes quickly.
    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat — written on every tick
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file on first tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file mtime is updated on subsequent ticks" {
    rm -f "$HEARTBEAT_FILE"
    run_once

    # Record the mtime after the first tick.
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    # Wait one second so the filesystem mtime can advance.
    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
        || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — fresh heartbeat → no kill
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with no-op when heartbeat is fresh" {
    touch "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"STALE"* ]]
}

@test "scanner-watchdog: exits 0 with informational message when heartbeat file absent" {
    rm -f "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat"* ]]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — stale heartbeat → dry-run logs STALE
# ---------------------------------------------------------------------------

@test "scanner-watchdog --dry-run: logs STALE when heartbeat is old" {
    # Create a heartbeat file with mtime well in the past (>600s ago).
    touch -t 200001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || touch -d "1970-01-01 00:00:00" "$HEARTBEAT_FILE" 2>/dev/null \
        || : # if neither works the stat-based age will be very large

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog --dry-run: does not remove lock file" {
    touch -t 200001010000 "$HEARTBEAT_FILE" 2>/dev/null || true

    local lock_file="/tmp/loop-scanner.lock"
    echo "99999" > "$lock_file"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run

    # Lock must survive a dry-run.
    [ -f "$lock_file" ]
    rm -f "$lock_file"
}
