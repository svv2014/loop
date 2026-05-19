#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#  1. scanner.sh touches scanner-heartbeat on every run_once() call.
#  2. watchdog.sh exits 0 when heartbeat is fresh.
#  3. watchdog.sh kills the scanner PID and removes the lock when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Minimal env required by env.sh sourcing in watchdog.sh.
    export LOOP_EXTRA_PATH=""
    export LOOP_SCANNER_INTERVAL=300

    # Source scanner function definitions only (same pattern as scanner.bats).
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
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# heartbeat file
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file on first tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "run_once: updates scanner-heartbeat mtime on each tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    # Force mtime to look old.
    touch -t 200001010000 "$hb"
    local mtime_old
    mtime_old=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    [ "$mtime_old" -lt "$mtime1" ]
    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb")
    [ "$mtime2" -gt "$mtime_old" ]
}

@test "run_once: does NOT create heartbeat when DRY_RUN=true" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "watchdog.sh: exits 0 silently when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run bash "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
}

@test "watchdog.sh: exits 0 when heartbeat is fresh" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    run bash "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    # No kill action should have been logged.
    if [ -f "$LOOP_LOG_DIR/loop-scanner-watchdog.log" ]; then
        run grep -c "ALERT" "$LOOP_LOG_DIR/loop-scanner-watchdog.log"
        [ "$output" = "0" ]
    fi
}

@test "watchdog.sh: kills scanner PID and removes lock when heartbeat is stale" {
    # Write a stale heartbeat (2000-01-01).
    touch -t 200001010000 "$LOOP_LOG_DIR/scanner-heartbeat"

    # Spin up a real process to act as the "wedged scanner".
    sleep 60 &
    local fake_pid=$!

    # Write a lock file pointing at the fake scanner PID.
    echo "$fake_pid" > /tmp/loop-scanner.lock

    run bash "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]

    # Lock file must be gone.
    [ ! -f /tmp/loop-scanner.lock ]

    # Process must be dead.
    ! kill -0 "$fake_pid" 2>/dev/null

    # Log must mention the kill.
    grep -q "killing wedged scanner" "$LOOP_LOG_DIR/loop-scanner-watchdog.log"
}
