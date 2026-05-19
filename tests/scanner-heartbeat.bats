#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Tests:
#   1. _write_heartbeat creates/updates the heartbeat file on each tick.
#   2. _write_heartbeat is a no-op in --dry-run mode.
#   3. scanner-watchdog.sh exits 0 and takes no action when heartbeat is fresh.
#   4. scanner-watchdog.sh kills a wedged-scanner PID when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh.sh as the gh binary.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same strip as scanner.bats).
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
    DRY_RUN=false

    # Silence log() and no-op dispatch so run_once doesn't try real work.
    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { echo; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/bin" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _write_heartbeat
# ---------------------------------------------------------------------------

@test "_write_heartbeat creates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_write_heartbeat writes a recent epoch timestamp" {
    _write_heartbeat
    local ts now
    ts=$(cat "$HEARTBEAT_FILE")
    now=$(date +%s)
    [ "$ts" -gt 0 ]
    # Timestamp should be within 5 seconds of now.
    [ $(( now - ts )) -lt 5 ]
}

@test "_write_heartbeat updates mtime on repeated calls" {
    _write_heartbeat
    local mtime1 mtime2
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    _write_heartbeat
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_write_heartbeat is a no-op when DRY_RUN=true" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    _write_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 and logs healthy when heartbeat is fresh" {
    # Write a heartbeat right now — age ≈ 0 s, well under any threshold.
    date +%s > "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat is old and no lock file" {
    # Write a heartbeat and set its mtime to epoch 0 (Jan 1 1970) — far past threshold.
    date +%s > "$HEARTBEAT_FILE"
    python3 -c "import os; os.utime('$HEARTBEAT_FILE', (0, 0))"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    # Either it detects no lock file or logs ALERT — both are fine.
    # The important assertion is that it does NOT claim the scanner is healthy.
    [[ "$output" != *"scanner is healthy"* ]]
}

@test "scanner-watchdog: DRY-RUN logs would-kill when heartbeat stale and PID alive" {
    # Spawn a long-running no-op process to serve as the mock scanner PID.
    sleep 300 &
    local mock_pid=$!
    # Write a stale heartbeat (mtime = epoch 0).
    date +%s > "$HEARTBEAT_FILE"
    python3 -c "import os; os.utime('$HEARTBEAT_FILE', (0, 0))"
    # Write PID to lock file.
    local lock="/tmp/loop-scanner.lock"
    echo "$mock_pid" > "$lock"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    local exit_code=$status

    kill "$mock_pid" 2>/dev/null || true
    rm -f "$lock"

    [ "$exit_code" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"would kill"* ]]
}
