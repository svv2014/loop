#!/usr/bin/env bats
# tests/lock-recovery.bats
#
# Tests for stale-lock recovery in lib/lock.sh:
#   (1) Dead-PID lock is stolen and emits a lock_recovered event with reason=dead_pid
#   (2) TTL-expired lock (live PID) is stolen and emits reason=ttl_expired
#   (3) Live lock within TTL is NOT stolen
#   (4) _lock_emit_recovered is a no-op when LOOP_MONITOR_URL is unset

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    export LOOP_LOCK_DIR="$BATS_TMPDIR/locks-$$"
    mkdir -p "$LOOP_LOCK_DIR"

    export EVENT_LOG="$BATS_TMPDIR/events-$$.log"
    rm -f "$EVENT_LOG"

    unset LOOP_MONITOR_URL
}

teardown() {
    rm -rf "$LOOP_LOCK_DIR"
    rm -f "$EVENT_LOG"
}

# ---------------------------------------------------------------------------
# Helper: source lock.sh with a stubbed _loop_emit_event that writes to EVENT_LOG
# ---------------------------------------------------------------------------
_source_lock_with_stub() {
    # Stub monitor before sourcing lock.sh so the lazy-load branch finds it
    _loop_emit_event() {
        echo "event_type=$1 payload=$2" >> "$EVENT_LOG"
    }
    # shellcheck source=../lib/lock.sh
    source "$REPO_ROOT/lib/lock.sh"
}

# ---------------------------------------------------------------------------
# (1) Dead-PID lock → stolen + lock_recovered(dead_pid) emitted
# ---------------------------------------------------------------------------

@test "lock recovery: dead-PID lock is stolen and emits dead_pid event" {
    _source_lock_with_stub

    local slug="test-dead-pid"
    local lock_file="$LOOP_LOCK_DIR/${slug}.lock"

    # Write a lock with a guaranteed-dead PID (use PID 1 which we can't kill,
    # but simulate "dead" by writing a non-existent PID in a subshell).
    # Strategy: write a PID that exited before we check it.
    local dead_pid
    (sleep 0) &
    dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    echo "$dead_pid" > "$lock_file"

    # Acquire with a 1-second max_wait so the test is fast
    loop_acquire_lock "$slug" 1

    # Lock should now be ours
    [ "$(cat "$lock_file")" = "$$" ]

    # The event should have been emitted
    grep -q "event_type=lock_recovered" "$EVENT_LOG"
    grep -q "dead_pid" "$EVENT_LOG"

    loop_release_lock "$slug"
}

# ---------------------------------------------------------------------------
# (2) TTL-expired lock (live PID) → stolen + lock_recovered(ttl_expired) emitted
# ---------------------------------------------------------------------------

@test "lock recovery: TTL-expired lock emits ttl_expired event" {
    _source_lock_with_stub

    local slug="test-ttl"
    local lock_file="$LOOP_LOCK_DIR/${slug}.lock"

    # Write a lock held by our own shell (PID $$), so kill-0 says "alive"
    echo "$$" > "$lock_file"
    # Back-date the file so lock_age > LOOP_LOCK_TTL
    touch -t "197001010000" "$lock_file"

    export LOOP_LOCK_TTL=1  # 1 second — any age will exceed it

    # Acquire — should steal the TTL-expired lock
    # (We can't actually steal our own PID easily in a test without a subprocess,
    # so we temporarily replace kill to always return 0 / say "alive" then
    # re-write a fresh lock after the test hook steals ours.)
    #
    # Simpler approach: write a lock from a short-lived background process,
    # let it exit, then backdating ensures TTL path triggers.
    local holder_pid
    (sleep 100) &
    holder_pid=$!
    echo "$holder_pid" > "$lock_file"
    touch -t "197001010000" "$lock_file"

    export LOOP_LOCK_TTL=1

    loop_acquire_lock "$slug" 5

    # Kill the background holder we spawned
    kill "$holder_pid" 2>/dev/null || true

    [ "$(cat "$lock_file")" = "$$" ]
    grep -q "event_type=lock_recovered" "$EVENT_LOG"
    grep -q "ttl_expired" "$EVENT_LOG"

    loop_release_lock "$slug"
}

# ---------------------------------------------------------------------------
# (3) Live lock within TTL is NOT stolen
# ---------------------------------------------------------------------------

@test "lock recovery: live lock within TTL is not stolen" {
    _source_lock_with_stub

    local slug="test-live"
    local lock_file="$LOOP_LOCK_DIR/${slug}.lock"

    export LOOP_LOCK_TTL=7200

    # Hold the lock from a background process that stays alive during the test
    (sleep 30) &
    local holder_pid=$!
    echo "$holder_pid" > "$lock_file"

    # Try to acquire with a 2-second max_wait — should time out (return 1)
    run loop_acquire_lock "$slug" 2
    kill "$holder_pid" 2>/dev/null || true

    [ "$status" -ne 0 ]  # timed out
    # No event should have been emitted
    [ ! -f "$EVENT_LOG" ] || ! grep -q "lock_recovered" "$EVENT_LOG"
}

# ---------------------------------------------------------------------------
# (4) _lock_emit_recovered is a no-op when LOOP_MONITOR_URL is unset
# ---------------------------------------------------------------------------

@test "lock recovery: emit is no-op with no LOOP_MONITOR_URL" {
    # Load lock.sh WITHOUT the stub — real _loop_emit_event path
    unset LOOP_MONITOR_URL
    # shellcheck source=../lib/lock.sh
    source "$REPO_ROOT/lib/lock.sh"

    # Should complete without error
    _lock_emit_recovered "test-slug" "99999" "dead_pid" 0
}
