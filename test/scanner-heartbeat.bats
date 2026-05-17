#!/usr/bin/env bats
# test/scanner-heartbeat.bats — bats coverage for scanner liveness heartbeat (#413).
#
# Tests:
#  - heartbeat file is created on the first tick (_scanner_write_heartbeat)
#  - heartbeat file mtime is updated on subsequent ticks
#  - dry-run mode does not write the heartbeat file
#  - restart-scanner-if-stale.sh reports "healthy" when heartbeat is fresh
#  - restart-scanner-if-stale.sh reports "STALE" when heartbeat is old
#  - restart-scanner-if-stale.sh --dry-run does not kill any PID
#  - watchdog exits gracefully when heartbeat file is absent (falls back to log)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/loop-logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Build a minimal source file containing only the heartbeat helpers extracted
    # from scanner.sh, so we can unit-test them without running the full scanner.
    local _src="$BATS_TMPDIR/heartbeat-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "LOOP_LOG_DIR='%s'\n" "$LOOP_LOG_DIR"
        printf "HEARTBEAT_FILE='%s/scanner-heartbeat'\n" "$LOOP_LOG_DIR"
        printf "DRY_RUN=false\n"
        printf "LOG_FILE='%s/scanner-test.log'\n" "$BATS_TMPDIR"
        # Pull _scanner_write_heartbeat from scanner.sh
        awk '/^_scanner_write_heartbeat\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
        # Pull _scanner_check_log_fd from scanner.sh
        awk '/^_scanner_check_log_fd\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"

    touch "$BATS_TMPDIR/scanner-test.log"
}

teardown() {
    rm -rf "$BATS_TMPDIR/loop-logs" "$BATS_TMPDIR/heartbeat-src.sh" \
           "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat unit tests
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file on first call" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    _scanner_write_heartbeat
    [ -f "$hb" ]
}

@test "_scanner_write_heartbeat: file contains a timestamp" {
    _scanner_write_heartbeat
    local content
    content=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Should match ISO 8601 date pattern written by scanner.sh
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "_scanner_write_heartbeat: updates mtime on subsequent calls" {
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat: no-op in dry-run mode" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    _scanner_write_heartbeat
    [ ! -f "$hb" ]
    DRY_RUN=false
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh integration tests (no real kills)
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale.sh: reports healthy when heartbeat is fresh" {
    date '+%Y-%m-%dT%H:%M:%SZ' > "$LOOP_LOG_DIR/scanner-heartbeat"

    LOOP_SCANNER_STALE_THRESHOLD=900 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "restart-scanner-if-stale.sh: reports STALE when heartbeat is old" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date '+%Y-%m-%dT%H:%M:%SZ' > "$hb"
    # Backdate 30 minutes — well past the 15-min threshold
    touch -t "$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null \
               || date -d '30 minutes ago' +%Y%m%d%H%M.%S)" "$hb"

    LOOP_SCANNER_STALE_THRESHOLD=900 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "restart-scanner-if-stale.sh: skips gracefully when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    # Also remove scanner log so both probes are absent
    rm -f "$LOOP_LOG_DIR/loop-scanner.log"

    run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing"* ]]
}

@test "restart-scanner-if-stale.sh: falls back to scanner log when heartbeat is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a fresh scanner log
    date '+%Y-%m-%dT%H:%M:%SZ' > "$LOOP_LOG_DIR/loop-scanner.log"

    LOOP_SCANNER_STALE_THRESHOLD=900 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}
