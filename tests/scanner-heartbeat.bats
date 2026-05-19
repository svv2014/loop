#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner liveness heartbeat (#413).
#
# Verifies:
#   1. run_once() writes the heartbeat file on every tick.
#   2. _scanner_check_stdout exits 1 when LOG_FILE is not writable.
#   3. The watchdog script exits clean when heartbeat is missing or fresh.
#   4. The watchdog prints kill intent (--dry-run) when heartbeat is stale.
#   5. The watchdog removes a stale lock when the scanner PID is dead.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions (same awk strip as scanner.bats).
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

    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log()                { :; }
    dispatch_direct()    { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs()    { return 0; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file — written on every run_once tick
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file on first tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: updates heartbeat file mtime on each tick" {
    touch -t 202001010000 "$HEARTBEAT_FILE"
    local before
    before=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    run_once
    local after
    after=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$after" -gt "$before" ]
}

@test "_scanner_heartbeat: writes PID to heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
    grep -q "$$" "$HEARTBEAT_FILE"
}

# ---------------------------------------------------------------------------
# _scanner_check_stdout — exits when log file is unwritable
# ---------------------------------------------------------------------------

@test "_scanner_check_stdout: does not exit when LOG_FILE is writable" {
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    run _scanner_check_stdout
    [ "$status" -eq 0 ]
}

@test "_scanner_check_stdout: exits 1 when LOG_FILE is not writable" {
    touch "$LOG_FILE"
    chmod 000 "$LOG_FILE"
    run _scanner_check_stdout
    chmod 644 "$LOG_FILE"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — liveness checks
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat file is missing (scanner not yet started)" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not have started"* ]]
}

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    touch "${LOOP_LOG_DIR}/scanner-heartbeat"
    LOOP_SCANNER_INTERVAL=300 run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner alive"* ]]
}

@test "scanner-watchdog: dry-run prints kill intent when heartbeat is stale" {
    touch -t 202001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"
    LOOP_SCANNER_INTERVAL=300 run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog: removes stale lock when scanner PID is dead" {
    local fake_lock="/tmp/loop-scanner-test-$$.lock"
    echo "99999999" > "$fake_lock"
    touch -t 202001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"
    LOOP_SCANNER_LOCK="$fake_lock" LOOP_SCANNER_INTERVAL=300 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    rm -f "$fake_lock"
    [[ "$output" == *"stale lock"* ]] || [[ "$output" == *"no live scanner"* ]]
}
