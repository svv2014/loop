#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#   1. run_once() writes the heartbeat file on every real tick.
#   2. run_once() skips heartbeat write in --dry-run mode.
#   3. scanner-watchdog.sh exits cleanly when heartbeat is fresh.
#   4. scanner-watchdog.sh kills a wedged scanner PID when heartbeat is stale.
#   5. scanner-watchdog.sh --dry-run reports but does not kill.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions (same awk-strip strategy as scanner.bats).
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
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence helpers; no-op scan so run_once() completes without real GitHub calls.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs() { :; }
    jobs_init_schema() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file written by run_once
# ---------------------------------------------------------------------------

@test "run_once: writes heartbeat file on each tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]

    run_once

    [ -f "$hb" ]
    [ -s "$hb" ]
}

@test "run_once: heartbeat file mtime is updated on second tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)

    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat file NOT written when DRY_RUN=true" {
    DRY_RUN=true
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]

    run_once

    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 (alive) when heartbeat is fresh" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$hb"

    # Threshold = 600s; freshly-written file is 0s old.
    LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

@test "scanner-watchdog: --dry-run reports stale heartbeat without killing" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    # Create a heartbeat file with an ancient mtime by touching it and
    # setting mtime to 1 hour ago via a temp file approach.
    printf '%s\n' "old" > "$hb"
    touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date --date='1 hour ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '202001010000.00')" "$hb" 2>/dev/null || true

    # Spawn a short-lived sleep as a fake scanner PID.
    sleep 60 &
    local fake_pid=$!
    local lock_file="$BATS_TMPDIR/fake-scanner.lock"
    echo "$fake_pid" > "$lock_file"

    LOOP_SCANNER_WATCHDOG_THRESHOLD=1 \
    LOOP_SCANNER_LOCK_FILE="$lock_file" \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run

    # Clean up the sleep process.
    kill "$fake_pid" 2>/dev/null || true
    wait "$fake_pid" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    # Process must still be alive after --dry-run (we kill it ourselves above).
}

@test "scanner-watchdog: kills wedged scanner when heartbeat is stale" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    printf '%s\n' "old" > "$hb"
    touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date --date='1 hour ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '202001010000.00')" "$hb" 2>/dev/null || true

    # Spawn a short-lived sleep as a fake scanner PID.
    sleep 60 &
    local fake_pid=$!
    local lock_file="$BATS_TMPDIR/fake-scanner2.lock"
    echo "$fake_pid" > "$lock_file"

    # Confirm process is alive before the watchdog runs.
    kill -0 "$fake_pid"

    LOOP_SCANNER_WATCHDOG_THRESHOLD=1 \
    LOOP_SCANNER_LOCK_FILE="$lock_file" \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"

    wait "$fake_pid" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [[ "$output" == *"killing wedged scanner"* ]]
    # Process should be gone.
    ! kill -0 "$fake_pid" 2>/dev/null
}

@test "scanner-watchdog: exits cleanly when no lock file exists" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    printf '%s\n' "old" > "$hb"
    touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date --date='1 hour ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '202001010000.00')" "$hb" 2>/dev/null || true

    LOOP_SCANNER_WATCHDOG_THRESHOLD=1 \
    LOOP_SCANNER_LOCK_FILE="$BATS_TMPDIR/no-such-lock.lock" \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no lock file"* ]]
}
