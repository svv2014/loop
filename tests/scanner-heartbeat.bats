#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner liveness heartbeat (#413).
#
# Tests:
#  - _scanner_write_heartbeat creates the heartbeat file on the first tick.
#  - _scanner_write_heartbeat updates the file mtime on subsequent ticks.
#  - _scanner_check_log_fd exits when the log file is not writable.
#  - restart-scanner-if-stale.sh reports "healthy" when heartbeat is fresh.
#  - restart-scanner-if-stale.sh reports "STALE" when heartbeat is old.
#  - restart-scanner-if-stale.sh --dry-run does not kill any process.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source just the helper functions from scanner.sh into current shell.
    local _src="$BATS_TMPDIR/heartbeat-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "LOOP_LOG_DIR='%s'\n" "$LOOP_LOG_DIR"
        printf "HEARTBEAT_FILE='%s/scanner-heartbeat'\n" "$LOOP_LOG_DIR"
        printf "LOG_FILE='%s/scanner-test.log'\n" "$BATS_TMPDIR"
        printf "DRY_RUN=false\n"
        awk '/^_scanner_write_heartbeat\(\)/,/^\}/' "$REPO_ROOT/scanner/scanner.sh"
        awk '/^_scanner_check_log_fd\(\)/,/^\}/' "$REPO_ROOT/scanner/scanner.sh"
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

@test "_scanner_write_heartbeat: file contains an ISO timestamp" {
    _scanner_write_heartbeat
    local content
    content=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "_scanner_write_heartbeat: updates mtime on repeated calls" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat: no-op when DRY_RUN=true" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$hb"
    _scanner_write_heartbeat
    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# _scanner_check_log_fd
# ---------------------------------------------------------------------------

@test "_scanner_check_log_fd: passes when log file is writable" {
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    _scanner_check_log_fd
}

@test "_scanner_check_log_fd: exits non-zero when log file is missing" {
    LOG_FILE="$BATS_TMPDIR/no-such-log.log"
    run _scanner_check_log_fd
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh
# ---------------------------------------------------------------------------

@test "watchdog: reports healthy when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date '+%Y-%m-%dT%H:%M:%SZ' > "$hb"
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "watchdog: reports STALE when heartbeat is old" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date '+%Y-%m-%dT%H:%M:%SZ' > "$hb"
    # Back-date the file mtime to 20 minutes ago
    touch -t "$(date -v-20M '+%Y%m%d%H%M' 2>/dev/null || date -d '20 minutes ago' '+%Y%m%d%H%M')" "$hb"
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "watchdog --dry-run: does not kill any process" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    date '+%Y-%m-%dT%H:%M:%SZ' > "$hb"
    touch -t "$(date -v-20M '+%Y%m%d%H%M' 2>/dev/null || date -d '20 minutes ago' '+%Y%m%d%H%M')" "$hb"
    # Write a fake lock with our own PID — watchdog must not kill us
    echo $$ > /tmp/loop-scanner.lock
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    rm -f /tmp/loop-scanner.lock
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    # Verify we are still alive
    kill -0 $$ 2>/dev/null
}

@test "watchdog: skips gracefully when heartbeat is absent and scanner log is missing" {
    # Neither heartbeat nor scanner log exist
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat" "$LOOP_LOG_DIR/loop-scanner.log"
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing"* ]]
}
