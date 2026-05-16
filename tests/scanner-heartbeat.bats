#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner heartbeat file is updated on every tick.
#
# Verifies that scanner.sh writes HEARTBEAT_FILE at the top of each run_once()
# call, and that scanner-watchdog.sh correctly identifies stale heartbeats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Pre-set log dir so env.sh does not create ~/.loop/logs during tests.
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

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
    export PATH="$BATS_TMPDIR/bin:$PATH"

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    HEARTBEAT_FILE="$BATS_TMPDIR/logs/scanner-heartbeat"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() and skip real scan work.
    log() { :; }
    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat written by run_once
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created on first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file mtime is updated on each tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")

    # Small sleep so the mtime can advance even on a 1-second filesystem.
    sleep 1.1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")

    [ "$mtime2" -gt "$mtime1" ]
}

@test "run_once: heartbeat file is NOT written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh logic
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    touch "$BATS_TMPDIR/logs/scanner-heartbeat"

    # Run watchdog with a very high stale threshold so a just-touched file passes.
    run env \
        LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
        LOOP_SCANNER_INTERVAL=9999 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

@test "scanner-watchdog: detects stale heartbeat when threshold is very small" {
    touch "$BATS_TMPDIR/logs/scanner-heartbeat"
    # Force stale by setting threshold to 0 seconds (any age is stale).
    # We use a subshell override: scanner-watchdog reads LOOP_SCANNER_INTERVAL.
    # Threshold = 2 * LOOP_SCANNER_INTERVAL; interval=0 → 0s threshold.
    # Use interval=1 so threshold=2s; then age of a just-touched file (0s) < 2s.
    # Instead, back-date the heartbeat file.

    # Back-date to 1 hour ago so it is definitely stale.
    touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '-1 hour' '+%Y%m%d%H%M.%S')" \
        "$BATS_TMPDIR/logs/scanner-heartbeat" 2>/dev/null \
        || touch -d "1970-01-01 00:00:00" "$BATS_TMPDIR/logs/scanner-heartbeat" 2>/dev/null \
        || true

    run env \
        LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    # Should report stale — either "ALERT" or "WARN: heartbeat stale"
    [[ "$output" == *"stale"* ]] || [[ "$output" == *"ALERT"* ]]
}

@test "scanner-watchdog: no-op when heartbeat file is missing and no lock file" {
    rm -f "$BATS_TMPDIR/logs/scanner-heartbeat"

    run env \
        LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    # Either "WARN: heartbeat stale ... no lock file" or similar
    [[ "$output" == *"stale"* ]] || [[ "$output" == *"WARN"* ]] || [[ "$output" == *"ALERT"* ]]
}
