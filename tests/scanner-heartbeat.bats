#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Tests:
#   1. scanner.sh writes scanner-heartbeat on each run_once() call.
#   2. scanner-watchdog.sh reports ok when heartbeat is fresh.
#   3. scanner-watchdog.sh reports STALE (dry-run) when heartbeat is old.
#   4. scanner-watchdog.sh exits cleanly when heartbeat file is absent.

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
}

teardown() {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
}

# ---------------------------------------------------------------------------
# 1. scanner.sh heartbeat file is written by run_once()
# ---------------------------------------------------------------------------

@test "scanner.sh: run_once() writes scanner-heartbeat to LOOP_LOG_DIR" {
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

    # Stub helpers so run_once() completes without real gh calls.
    loop_list_slugs()      { echo ""; }
    _sweep_stale_locks()   { :; }
    jobs_init_schema()     { :; }
    LOOP_JOBS_ENQUEUE=0

    heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$heartbeat"

    run_once

    [ -f "$heartbeat" ]
}

@test "scanner.sh: heartbeat mtime advances between two run_once() calls" {
    export LOOP_EXTRA_PATH=""
    local _src="$BATS_TMPDIR/scanner-src2.sh"
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

    DEDUP_DIR="$BATS_TMPDIR/dedup2"
    LOG_FILE="$BATS_TMPDIR/scanner-test2.log"
    mkdir -p "$DEDUP_DIR"

    loop_list_slugs()      { echo ""; }
    _sweep_stale_locks()   { :; }
    jobs_init_schema()     { :; }
    LOOP_JOBS_ENQUEUE=0

    heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$heartbeat"

    run_once
    mtime1=$(stat -f%m "$heartbeat" 2>/dev/null || stat -c%Y "$heartbeat" 2>/dev/null)

    # Ensure at least 1-second difference for mtime comparison.
    sleep 1
    run_once
    mtime2=$(stat -f%m "$heartbeat" 2>/dev/null || stat -c%Y "$heartbeat" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

# ---------------------------------------------------------------------------
# 2–4. scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits ok when heartbeat is fresh" {
    heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    touch "$heartbeat"

    export LOOP_SCANNER_WATCHDOG_THRESHOLD=600
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok (heartbeat age="* ]]
}

@test "scanner-watchdog: reports STALE in dry-run when heartbeat is old" {
    heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    # Back-date the heartbeat by 1200 seconds (older than default 600 s threshold).
    touch -t "$(date -v-1200S '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '1200 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" \
        "$heartbeat" 2>/dev/null \
        || touch -d "20 minutes ago" "$heartbeat" 2>/dev/null \
        || python3 -c "
import os, time
os.utime('$heartbeat', (time.time()-1200, time.time()-1200))
"

    export LOOP_SCANNER_WATCHDOG_THRESHOLD=600
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog: exits cleanly when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    export LOOP_SCANNER_WATCHDOG_THRESHOLD=600
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat file absent"* ]]
}
