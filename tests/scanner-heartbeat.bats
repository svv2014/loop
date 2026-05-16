#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 liveness heartbeat.
#
# Verifies that:
#   1. run_once() writes a timestamp to HEARTBEAT_FILE on every tick.
#   2. scanner-watchdog.sh exits 0 (healthy) when heartbeat is fresh.
#   3. scanner-watchdog.sh kills the scanner PID when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same pattern as scanner.bats).
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
    touch "$LOG_FILE"

    # Minimal stubs so run_once doesn't try to poll GitHub.
    log()              { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { return 0; }
    loop_list_slugs()  { return 0; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" \
           "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat — run_once() writes the file
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file on first tick" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=false
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains a timestamp" {
    DRY_RUN=false
    run_once
    [ -f "$HEARTBEAT_FILE" ]
    local content
    content=$(cat "$HEARTBEAT_FILE")
    # Timestamp format: YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "run_once: heartbeat mtime is updated on each tick" {
    DRY_RUN=false
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat is NOT written in dry-run mode" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — healthy scanner
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    # Write a heartbeat with current timestamp.
    date '+%Y-%m-%d %H:%M:%S' > "$HEARTBEAT_FILE"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_WATCHDOG_THRESHOLD=600 \
        LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — stale heartbeat triggers restart
# ---------------------------------------------------------------------------

@test "scanner-watchdog: detects stale heartbeat in dry-run" {
    # Write a heartbeat with a mtime 700 seconds in the past.
    date '+%Y-%m-%d %H:%M:%S' > "$HEARTBEAT_FILE"
    # Back-date the file by 700s.  touch -t on macOS: [[CC]YY]MMDDhhmm[.SS]
    # Use perl as a portable fallback for setting mtime.
    if ! touch -A -0000700 "$HEARTBEAT_FILE" 2>/dev/null; then
        perl -e 'utime(time()-700, time()-700, $ARGV[0])' "$HEARTBEAT_FILE"
    fi

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_WATCHDOG_THRESHOLD=600 \
        LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog: skips gracefully when no heartbeat file exists" {
    rm -f "$HEARTBEAT_FILE"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_WATCHDOG_THRESHOLD=600 \
        LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file"* ]]
}
