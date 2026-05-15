#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat (issue #413).
#
# Verifies that _write_heartbeat updates the heartbeat file on every tick,
# and that scanner-watchdog.sh kills a stale scanner PID and leaves a fresh
# one alone.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source just the heartbeat helper from scanner.sh (stop before acquire_lock).
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

    log() { :; }
    dispatch_direct() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _write_heartbeat
# ---------------------------------------------------------------------------

@test "_write_heartbeat: creates heartbeat file" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    _write_heartbeat
    [ -f "$hb" ]
}

@test "_write_heartbeat: file contains a unix timestamp" {
    _write_heartbeat
    local ts
    ts=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Must be a number greater than 0
    [ "$ts" -gt 0 ]
}

@test "_write_heartbeat: updates mtime on each call" {
    _write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
          || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    # Small sleep to ensure mtime changes (1 second resolution on most FS).
    sleep 1.1
    _write_heartbeat

    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
          || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    [ "$mtime2" -gt "$mtime1" ]
}

@test "_write_heartbeat: no-ops in dry-run mode" {
    DRY_RUN=true
    _write_heartbeat
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with no heartbeat file (scanner not yet started)" {
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file"* ]]
}

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat (age = 0s)
    date +%s > "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_WATCHDOG_STALE_SECONDS=900 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat OK"* ]]
}

@test "scanner-watchdog: kills stale scanner PID and removes lock" {
    # Write a heartbeat timestamped far in the past (simulate stale).
    echo "1" > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || touch -d "2000-01-01 00:00:00" "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || true

    # Spawn a real sleep process as a stand-in for the stale scanner.
    sleep 30 &
    local fake_pid=$!
    local lock_file="/tmp/loop-scanner.lock"
    echo "$fake_pid" > "$lock_file"

    LOOP_WATCHDOG_STALE_SECONDS=1 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"

    # Clean up: kill the sleep if still alive (watchdog may have beaten us).
    kill "$fake_pid" 2>/dev/null || true
    rm -f "$lock_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog: handles missing lock file gracefully when stale" {
    echo "1" > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || touch -d "2000-01-01 00:00:00" "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || true

    rm -f /tmp/loop-scanner.lock

    LOOP_WATCHDOG_STALE_SECONDS=1 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
