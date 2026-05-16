#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written by scanner (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""
    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner functions (same strategy as scanner.bats).
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

    # Stub out dispatch and log so run_once doesn't actually poll GitHub.
    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-hb-src.sh" \
           "$BATS_TMPDIR/scanner-hb-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat: run_once writes the file
# ---------------------------------------------------------------------------

@test "run_once: writes scanner-heartbeat file to LOOP_LOG_DIR" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ -f "$hb" ]
}

@test "run_once: scanner-heartbeat contains a timestamp" {
    run_once
    local content
    content=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Must look like YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "run_once: scanner-heartbeat mtime is updated on each call" {
    # stat -f%m is macOS-specific; skip on platforms where it is unavailable.
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$hb" 2>/dev/null || touch "$hb"
    local before
    before=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null) || \
        skip "stat not available on this platform"
    sleep 1
    run_once
    local after
    after=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    [ "$after" -gt "$before" ]
}

@test "run_once: heartbeat is NOT written in dry-run mode" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: stale threshold detection
# ---------------------------------------------------------------------------

@test "scanner-watchdog --dry-run: exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat.
    date '+%Y-%m-%d %H:%M:%S' > "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

@test "scanner-watchdog --dry-run: reports stale when heartbeat is old" {
    # Write a heartbeat with a past mtime (simulate wedged scanner).
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date '+%Y-%m-%d %H:%M:%S' > "$hb"
    # Back-date by 1 hour using touch -t.
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '-1 hour' '+%Y%m%d%H%M' 2>/dev/null || echo '200001010000')" "$hb"
    # Set a low threshold so the 1-hour-old file is definitely stale.
    export LOOP_SCANNER_WATCHDOG_STALE=60
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog --dry-run: exits 0 when heartbeat file does not exist yet" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    # age=0 < threshold → considered fresh (scanner has not ticked yet).
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
}
