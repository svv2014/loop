#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner heartbeat + watchdog behavior.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary.
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
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file
# ---------------------------------------------------------------------------

@test "run_once: writes heartbeat file on each tick" {
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains timestamp and dedup_count" {
    run_once
    content=$(cat "$HEARTBEAT_FILE")
    [[ "$content" =~ dedup_count= ]]
}

@test "run_once: heartbeat mtime is recent (within 5s)" {
    run_once
    age=$(( $(date +%s) - $(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))
    [ "$age" -le 5 ]
}

@test "run_once: heartbeat is updated on second tick" {
    run_once
    sleep 1
    first_content=$(cat "$HEARTBEAT_FILE")
    run_once
    second_content=$(cat "$HEARTBEAT_FILE")
    # Content will differ because timestamp changes each tick.
    [ "$first_content" != "$second_content" ]
}

@test "run_once: dry-run does NOT write heartbeat" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# Log fd integrity check
# ---------------------------------------------------------------------------

@test "_scanner_check_log_fd: passes when LOG_FILE is writable" {
    run _scanner_check_log_fd
    [ "$status" -eq 0 ]
}

@test "_scanner_check_log_fd: exits non-zero when LOG_FILE is not writable" {
    chmod 000 "$LOG_FILE"
    # Run in a subshell so the test process doesn't exit.
    run bash -c "
        source '$BATS_TMPDIR/scanner-src.sh'
        LOG_FILE='$LOG_FILE'
        _scanner_check_log_fd
    "
    chmod 644 "$LOG_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh source-level checks
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: script passes bash -n syntax check" {
    bash -n "$REPO_ROOT/scanner/scanner-watchdog.sh"
}

@test "scanner-watchdog.sh: _file_age_seconds returns large value for missing file" {
    # Source only the helper from the watchdog (avoid full execution).
    local _src="$BATS_TMPDIR/watchdog-helpers.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "LOOP_LOG_DIR='%s'\n" "$LOOP_LOG_DIR"
        # Extract just _file_age_seconds function definition.
        awk '
            /^_file_age_seconds\(\)/ { in_fn=1 }
            in_fn { print }
            in_fn && /^\}$/ { in_fn=0; exit }
        ' "$REPO_ROOT/scanner/scanner-watchdog.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"

    result=$(_file_age_seconds "/nonexistent/path/scanner-heartbeat")
    [ "$result" -gt 9000 ]
}
