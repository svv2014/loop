#!/usr/bin/env bats
# tests/qa-handler-lock-wedge.bats
#
# Regression test for the qa-handler lock-wedge scenario (issue #409).
#
# When a qa-handler process is killed (SIGKILL or silent crash), the lock
# file is left on disk. The next loop_acquire_lock call must:
#   (a) Detect the dead PID
#   (b) Steal the lock
#   (c) Emit a lock_recovered event
#
# This simulates the "kill a qa-handler mid-run" scenario — after the kill,
# the next scanner tick's loop_acquire_lock call re-acquires cleanly.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    export LOOP_LOCK_DIR="$BATS_TMPDIR/qa-locks-$$"
    mkdir -p "$LOOP_LOCK_DIR"

    export EVENT_LOG="$BATS_TMPDIR/qa-events-$$.log"
    rm -f "$EVENT_LOG"

    unset LOOP_MONITOR_URL
}

teardown() {
    rm -rf "$LOOP_LOCK_DIR"
    rm -f "$EVENT_LOG"
}

# ---------------------------------------------------------------------------
# Simulate: qa-handler spawned, held lock, was SIGKILLed → lock file survives.
# Next loop_acquire_lock (simulating the next scanner dispatch) steals it.
# ---------------------------------------------------------------------------

@test "qa-handler SIGKILL: next acquire steals orphaned lock and emits event" {
    # Stub event emission so we can observe it
    _loop_emit_event() {
        echo "event_type=$1 payload=$2" >> "$EVENT_LOG"
    }
    # shellcheck source=../lib/lock.sh
    source "$REPO_ROOT/lib/lock.sh"

    local slug="qa-wedge-test"
    local lock_file="$LOOP_LOCK_DIR/${slug}.lock"

    # Simulate a qa-handler that was SIGKILLed: spawn a process, let it write
    # the lock, then kill it without giving it a chance to clean up.
    (
        echo "$$" > "$lock_file"
        sleep 60
    ) &
    local killed_pid=$!
    echo "$killed_pid" > "$lock_file"
    kill -9 "$killed_pid" 2>/dev/null || true
    wait "$killed_pid" 2>/dev/null || true

    # Lock file still exists with the dead PID
    [ -f "$lock_file" ]
    [ "$(cat "$lock_file")" = "$killed_pid" ]

    # Simulate the next scanner tick: try to acquire the same lock
    loop_acquire_lock "$slug" 5

    # We should now hold the lock
    [ "$(cat "$lock_file")" = "$$" ]

    # A lock_recovered event must have been emitted
    grep -q "event_type=lock_recovered" "$EVENT_LOG"
    grep -q "dead_pid" "$EVENT_LOG"

    loop_release_lock "$slug"

    # After release, lock file should be gone
    [ ! -f "$lock_file" ]
}

# ---------------------------------------------------------------------------
# Confirm: lock release is idempotent (double-release doesn't error)
# ---------------------------------------------------------------------------

@test "qa-handler lock: release is idempotent" {
    # shellcheck source=../lib/lock.sh
    source "$REPO_ROOT/lib/lock.sh"

    local slug="idempotent-release"
    loop_acquire_lock "$slug" 5
    loop_release_lock "$slug"
    loop_release_lock "$slug"  # second release must not error
}
