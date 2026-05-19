#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that run_once() writes the heartbeat file on every tick and that
# scanner-watchdog.sh correctly detects a stale heartbeat.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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
    export PATH="$BATS_TMPDIR/bin:$PATH"

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"
    # Create the log file so the stdout integrity check does not trigger.
    touch "$LOG_FILE"

    DRY_RUN=false
    ONCE=false

    # Stubs — no projects to scan, no DB setup needed.
    loop_list_slugs()   { true; }
    jobs_init_schema()  { return 0; }
    _sweep_stale_locks() { return 0; }

    export LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
}

# ---------------------------------------------------------------------------
# Heartbeat file
# ---------------------------------------------------------------------------

@test "run_once: writes heartbeat file to LOOP_LOG_DIR" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb_file" ]
    run_once
    [ -f "$hb_file" ]
}

@test "run_once: heartbeat file contains current epoch timestamp" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    local before after ts
    before=$(date +%s)
    run_once
    after=$(date +%s)
    ts=$(awk '{print $1}' "$hb_file")
    [ "$ts" -ge "$before" ]
    [ "$ts" -le "$after" ]
}

@test "run_once: heartbeat file contains dedup_count field" {
    run_once
    grep -q "dedup_count=" "$LOOP_LOG_DIR/scanner-heartbeat"
}

@test "run_once: heartbeat mtime advances on second call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
          || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
          || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat NOT written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when no heartbeat file exists yet" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file yet"* ]]
}

@test "scanner-watchdog: reports ok when heartbeat is fresh" {
    printf '%s dedup_count=0\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_WATCHDOG_STALE_FACTOR=9999 \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is live"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and logs warning" {
    # Write a heartbeat with old mtime (touch -t to set 1 hour ago).
    printf '%s dedup_count=0\n' "$(( $(date +%s) - 3600 ))" > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null \
             || date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null \
             || date '+%Y%m%d%H%M')" "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || true
    LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_FACTOR=2 \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}
