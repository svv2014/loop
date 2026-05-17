#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes heartbeat on every tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh.sh as gh.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export LOOP_EXTRA_PATH=""

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh definitions, same approach as scanner.bats.
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

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    # Stub out project scanning so run_once completes quickly.
    loop_list_slugs() { return 0; }
    _sweep_stale_locks() { return 0; }
    jobs_init_schema() { return 0; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: creates heartbeat file on first tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains unix timestamp and PID" {
    run_once
    [ -f "$HEARTBEAT_FILE" ]
    local ts pid
    read -r ts pid < "$HEARTBEAT_FILE"
    # Timestamp must be a plausible unix epoch (> 2020-01-01 = 1577836800).
    [ "$ts" -gt 1577836800 ]
    # PID must be a positive integer.
    [ "$pid" -gt 0 ]
}

@test "run_once: heartbeat mtime is updated on second tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
             || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    # Ensure at least 1 second passes so mtime changes.
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
             || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat not written when DRY_RUN=true" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "scanner-watchdog.sh: exits 0 and logs ok when heartbeat is fresh" {
    # Write a current heartbeat.
    printf '%s %s\n' "$(date +%s)" "$$" > "$HEARTBEAT_FILE"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat ok"* ]]
}

@test "scanner-watchdog.sh: dry-run reports stale when heartbeat is old" {
    # Write a heartbeat with mtime 1 hour ago by using touch -t.
    local old_time
    old_time=$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null \
               || date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null \
               || echo "")
    if [ -z "$old_time" ]; then
        skip "cannot set old mtime on this platform"
    fi
    printf '%s %s\n' "0" "$$" > "$HEARTBEAT_FILE"
    touch -t "$old_time" "$HEARTBEAT_FILE"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
