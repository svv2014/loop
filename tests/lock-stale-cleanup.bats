#!/usr/bin/env bats
# tests/lock-stale-cleanup.bats — integration test for stale-lock self-healing (#403).
#
# Verifies that loop_acquire_lock and _sweep_stale_locks both reclaim lock files
# whose recorded PIDs are no longer alive.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOCK_DIR="$BATS_TMPDIR/loop-locks-$$"
    mkdir -p "$LOOP_LOCK_DIR"

    # Minimal env required by lock.sh (no other libs needed).
    # shellcheck source=../lib/lock.sh
    source "$REPO_ROOT/lib/lock.sh"
}

teardown() {
    rm -rf "$LOOP_LOCK_DIR"
}

# ---------------------------------------------------------------------------
# loop_acquire_lock — stale PID detection
# ---------------------------------------------------------------------------

@test "loop_acquire_lock: acquires lock when lock file contains a dead PID" {
    local dead_pid
    ( exit 0 ) &
    dead_pid=$!
    wait "$dead_pid"

    echo "$dead_pid" > "$LOOP_LOCK_DIR/test-99.lock"

    # Call directly (not via `run`) so the trap installs in this shell and
    # the lock file is not released before we can inspect it.
    loop_acquire_lock "test-99" 5
    local rc=$?
    [ "$rc" -eq 0 ]
    # Lock file should now contain OUR PID, not the dead one.
    [ "$(cat "$LOOP_LOCK_DIR/test-99.lock" 2>/dev/null)" = "$$" ]
    # Cleanup: release so teardown does not see leftover state.
    loop_release_lock "test-99"
}

@test "loop_acquire_lock: acquires lock when lock file is empty" {
    echo "" > "$LOOP_LOCK_DIR/test-99.lock"

    loop_acquire_lock "test-99" 5
    local rc=$?
    [ "$rc" -eq 0 ]
    [ "$(cat "$LOOP_LOCK_DIR/test-99.lock" 2>/dev/null)" = "$$" ]
    loop_release_lock "test-99"
}

@test "loop_acquire_lock: stale lock file is gone after successful acquire" {
    local dead_pid
    ( exit 0 ) &
    dead_pid=$!
    wait "$dead_pid"

    echo "$dead_pid" > "$LOOP_LOCK_DIR/stale-item.lock"

    loop_acquire_lock "stale-item" 5
    # The lock was reclaimed — our PID is now the holder.
    [ "$(cat "$LOOP_LOCK_DIR/stale-item.lock")" = "$$" ]
}

@test "loop_acquire_lock: does not acquire lock held by a live PID" {
    # Start a background process that holds the lock.
    local holder_pid
    ( echo "$$" > "$LOOP_LOCK_DIR/live-item.lock"; sleep 30 ) &
    holder_pid=$!

    # Write holder PID into the lock file (the subshell writes its own $$ which
    # is the subshell's PID, not $holder_pid; overwrite with the real PID).
    echo "$holder_pid" > "$LOOP_LOCK_DIR/live-item.lock"

    # Try to acquire with a very short timeout — must fail because PID is alive.
    run loop_acquire_lock "live-item" 3
    [ "$status" -ne 0 ]

    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _sweep_stale_locks — scanner pre-tick sweep
# ---------------------------------------------------------------------------

@test "_sweep_stale_locks: removes lock file with dead PID" {
    # Need the scanner's _sweep_stale_locks — source it from scanner.sh via
    # the same awk extraction strategy used in scanner.bats.
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs-$$"
    mkdir -p "$LOOP_LOG_DIR"

    local _src="$BATS_TMPDIR/scanner-sweep-src.sh"
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
    export LOOP_EXTRA_PATH=""
    # shellcheck disable=SC1090
    source "$_src"

    log() { true; }  # suppress scanner log output during test

    local dead_pid
    ( exit 0 ) &
    dead_pid=$!
    wait "$dead_pid"

    echo "$dead_pid" > "$LOOP_LOCK_DIR/loop-pr-999.lock"

    _sweep_stale_locks

    [ ! -f "$LOOP_LOCK_DIR/loop-pr-999.lock" ]
}

@test "_sweep_stale_locks: preserves lock file with live PID" {
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs-$$"
    mkdir -p "$LOOP_LOG_DIR"

    local _src="$BATS_TMPDIR/scanner-sweep-live-src.sh"
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
    export LOOP_EXTRA_PATH=""
    # shellcheck disable=SC1090
    source "$_src"

    log() { true; }

    # Write our own PID (current shell — definitely alive).
    echo "$$" > "$LOOP_LOCK_DIR/loop-pr-active.lock"

    _sweep_stale_locks

    [ -f "$LOOP_LOCK_DIR/loop-pr-active.lock" ]
}
