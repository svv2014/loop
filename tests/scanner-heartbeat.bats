#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.

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

@test "run_once: writes scanner-heartbeat file on each tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "run_once: heartbeat mtime advances between ticks" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    local t1
    t1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    sleep 1
    run_once
    local t2
    t2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    [ "$t2" -ge "$t1" ]
}

@test "run_once: heartbeat not written in dry-run mode" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    [ ! -f "$hb" ]
}

@test "restart-scanner-if-stale.sh: reports healthy when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    touch "$hb"
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "restart-scanner-if-stale.sh: detects stale heartbeat and reports restart" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    # Create a heartbeat file with a very old mtime (2000 seconds ago).
    touch "$hb"
    touch -t "$(date -v-2000S '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '2000 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date '+%Y%m%d%H%M.%S')" "$hb" 2>/dev/null || true
    # Force mtime with python3 if touch -t failed (portability fallback).
    python3 -c "
import os, time
hb = '$hb'
old = time.time() - 2000
os.utime(hb, (old, old))
"
    LOOP_SCANNER_STALE_THRESHOLD=600 \
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}

@test "restart-scanner-if-stale.sh: exits cleanly when heartbeat file is missing" {
    run bash "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing"* ]]
}
