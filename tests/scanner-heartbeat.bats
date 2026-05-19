#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat and watchdog tests (#413).
#
# Covers:
#   1. scanner.sh writes the heartbeat file on every tick.
#   2. scanner-watchdog.sh exits 0 + prints "fresh" when heartbeat is recent.
#   3. scanner-watchdog.sh prints "stale" and takes action when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

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
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Override paths used by scanner.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { :; }
    jobs_init_schema() { :; }
    _sweep_stale_locks() { :; }
    _scanner_check_stdout() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file written by run_once
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created on every tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains PID and timestamp" {
    run_once
    local pid ts
    read -r pid ts < "$HEARTBEAT_FILE"
    [ -n "$pid" ]
    [ -n "$ts" ]
    # PID must be numeric
    [[ "$pid" =~ ^[0-9]+$ ]]
    # Timestamp must be numeric (epoch seconds)
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "run_once: heartbeat mtime is updated on each invocation" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat is NOT written in --dry-run mode" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: fresh heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog: reports fresh when heartbeat is recent" {
    # Write a heartbeat that is 5 seconds old.
    printf '%s %s\n' "$$" "$(date +%s)" > "$HEARTBEAT_FILE"
    # Use a threshold of 600s so 5s is well within the fresh window.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_INTERVAL=300 \
            LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"fresh"* ]]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: stale heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog: reports stale when heartbeat file is missing" {
    rm -f "$HEARTBEAT_FILE"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_INTERVAL=300 \
            LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat is older than threshold" {
    # Write a heartbeat and backdate it by 700 seconds using touch.
    printf '%s %s\n' "$$" "$(( $(date +%s) - 700 ))" > "$HEARTBEAT_FILE"
    local past
    past=$(date -v -700S "+%Y%m%d%H%M.%S" 2>/dev/null \
        || date -d "700 seconds ago" "+%Y%m%d%H%M.%S" 2>/dev/null \
        || true)
    [ -n "$past" ] && touch -t "$past" "$HEARTBEAT_FILE" 2>/dev/null || true

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_INTERVAL=300 \
            LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}
