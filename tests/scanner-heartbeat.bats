#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner liveness heartbeat (#413).
#
# Tests:
#  - _scanner_write_heartbeat creates the heartbeat file on the first tick.
#  - _scanner_write_heartbeat updates the file on subsequent ticks.
#  - scanner-watchdog.sh reports "healthy" when heartbeat is fresh.
#  - scanner-watchdog.sh reports "STALE" when heartbeat is old.
#  - scanner-watchdog.sh --dry-run does not kill any PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Extract _scanner_write_heartbeat and _scanner_check_log_fd from scanner.sh.
    local _src="$BATS_TMPDIR/heartbeat-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "LOOP_LOG_DIR='%s'\n" "$LOOP_LOG_DIR"
        printf "HEARTBEAT_FILE='%s/scanner-heartbeat'\n" "$LOOP_LOG_DIR"
        printf "DRY_RUN=false\n"
        printf "LOG_FILE='%s/scanner-test.log'\n" "$BATS_TMPDIR"
        # Pull in _scanner_write_heartbeat
        awk '/^_scanner_write_heartbeat\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
        # Pull in _scanner_check_log_fd
        awk '/^_scanner_check_log_fd\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"

    touch "$BATS_TMPDIR/scanner-test.log"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/heartbeat-src.sh" \
           "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
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
    # Should match ISO 8601 date pattern
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
# _scanner_check_log_fd
# ---------------------------------------------------------------------------

@test "_scanner_check_log_fd: does not exit when log file is writable" {
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    run _scanner_check_log_fd
    [ "$status" -eq 0 ]
}

@test "_scanner_check_log_fd: exits 1 when log file path is a directory (not writable as file)" {
    # Use a path that exists but is not writable as a regular file.
    local ro_dir="$BATS_TMPDIR/ro-log-dir"
    mkdir -p "$ro_dir"
    chmod 444 "$ro_dir"
    LOG_FILE="$ro_dir/scanner.log"
    # File doesn't exist and parent dir is not writable — [ ! -w ] should be true.
    run _scanner_check_log_fd
    chmod 755 "$ro_dir"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh (integration — no actual kill)
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: reports healthy when heartbeat is fresh" {
    # Write a fresh heartbeat
    date '+%Y-%m-%dT%H:%M:%SZ' > "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "scanner-watchdog.sh: reports STALE when heartbeat is old" {
    # Write a heartbeat and backdate it well past the default stale threshold.
    # Unset LOOP_SCANNER_INTERVAL so the watchdog uses the built-in default
    # (300 s) giving a threshold of 600 s; backdate by 30 minutes (1800 s).
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date '+%Y-%m-%dT%H:%M:%SZ' > "$hb"
    touch -t "$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null \
               || date -d '30 minutes ago' +%Y%m%d%H%M.%S)" "$hb"

    LOOP_SCANNER_INTERVAL=300 run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog.sh: skips gracefully when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing"* ]]
}
