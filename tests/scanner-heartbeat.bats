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
    touch "$LOG_FILE"

    DRY_RUN=false
    ONCE=false

    # Stub loop_list_slugs to return nothing (no projects to scan).
    loop_list_slugs() { true; }
    # Stub jobs_init_schema to avoid DB setup.
    jobs_init_schema() { return 0; }
    # Stub _sweep_stale_locks to be a no-op.
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
    local before after content ts

    before=$(date +%s)
    run_once
    after=$(date +%s)

    content=$(cat "$hb_file")
    # First token is the epoch timestamp.
    ts=$(echo "$content" | awk '{print $1}')
    [ "$ts" -ge "$before" ]
    [ "$ts" -le "$after" ]
}

@test "run_once: heartbeat file contains dedup_count field" {
    run_once
    grep -q "dedup_count=" "$LOOP_LOG_DIR/scanner-heartbeat"
}

@test "run_once: heartbeat mtime updated on second call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
          || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    # Sleep just enough for mtime to advance (1s resolution on most FSes).
    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
          || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat NOT written in dry-run mode" {
    DRY_RUN=true
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    [ ! -f "$hb_file" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when no heartbeat file exists yet" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb_file"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file yet"* ]]
}

@test "scanner-watchdog: reports ok when heartbeat is fresh" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    printf '%s dedup_count=0\n' "$(date +%s)" > "$hb_file"

    # Use a very large stale factor so the just-written file is never stale.
    LOOP_WATCHDOG_STALE_FACTOR=9999 \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is live"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and logs warning" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a heartbeat with a timestamp 1 hour in the past.
    printf '%s dedup_count=0\n' "$(( $(date +%s) - 3600 ))" > "$hb_file"
    # Back-date the file mtime to 1 hour ago (touch -t or touch -d).
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$hb_file" 2>/dev/null || true

    LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_FACTOR=2 \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}
