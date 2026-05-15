#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is written on every tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

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

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    # Stub out functions that hit external services.
    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once: writes scanner-heartbeat file on every tick" {
    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$heartbeat_file" ]
    run_once
    [ -f "$heartbeat_file" ]
}

@test "run_once: heartbeat contains a recent epoch timestamp" {
    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    local ts
    ts=$(cat "$heartbeat_file")
    local now
    now=$(date +%s)
    # Timestamp must be a number within 5 seconds of now.
    [ "$ts" -gt 0 ]
    [ $(( now - ts )) -le 5 ]
}

@test "run_once: heartbeat is refreshed on each successive tick" {
    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    local ts1
    ts1=$(cat "$heartbeat_file")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "$heartbeat_file")
    [ "$ts2" -ge "$ts1" ]
}

@test "run_once: heartbeat not written in dry-run mode" {
    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    DRY_RUN=true
    run_once
    [ ! -f "$heartbeat_file" ]
}

@test "scanner-watchdog.sh: exits 0 when heartbeat is fresh" {
    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    date +%s > "$heartbeat_file"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "scanner OK"
}

@test "scanner-watchdog.sh: reports stale when heartbeat is old" {
    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a timestamp from the distant past.
    echo "1" > "$heartbeat_file"
    touch -t 200001010000 "$heartbeat_file" 2>/dev/null || true
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "stale"
}

@test "scanner-watchdog.sh: exits 0 when no heartbeat file exists" {
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "no heartbeat"
}
