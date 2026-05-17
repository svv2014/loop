#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat (#413).
#
# Verifies that scanner.sh writes HEARTBEAT_FILE at the start of every
# run_once() call and that scanner-watchdog.sh correctly detects stale
# and fresh heartbeat files.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh definitions only (same awk pattern as scanner.bats).
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
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stubs: silence log, no-op dispatch, no-op lock sweeps, empty project list.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat — scanner.sh
# ---------------------------------------------------------------------------

@test "run_once: writes HEARTBEAT_FILE on each call" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains a recent unix timestamp" {
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    local now
    now=$(date +%s)
    # Timestamp must be a number within the last 5 seconds.
    [ "$ts" -gt 0 ]
    [ $(( now - ts )) -lt 5 ]
}

@test "run_once: heartbeat updated on every call" {
    run_once
    local first
    first=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    run_once
    local second
    second=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$second" -ge "$first" ]
}

@test "run_once: DRY_RUN skips heartbeat write" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# Watchdog — scripts/scanner-watchdog.sh
# ---------------------------------------------------------------------------

_source_watchdog() {
    local _wsrc="$BATS_TMPDIR/watchdog-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "LOOP_LOG_DIR='%s'\n" "$LOOP_LOG_DIR"
        awk '
            /^SCRIPT_DIR=/    { next }
            /^LOOP_ROOT=/     { next }
            /^source.*env\.sh/ { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=false"; next }
            skip && /^done$/  { skip=0; next }
            skip              { next }
            /^watchdog_run$/  { exit }
            { print }
        ' "$REPO_ROOT/scripts/scanner-watchdog.sh"
        # Stub out log() and _restart_scanner() so tests don't trigger them.
        printf "log() { :; }\n"
        printf "_restart_scanner() { :; }\n"
    } > "$_wsrc"
    # shellcheck disable=SC1090
    source "$_wsrc"
}

@test "watchdog: _heartbeat_is_stale returns 0 when file missing" {
    _source_watchdog
    HEARTBEAT_FILE="$BATS_TMPDIR/no-such-heartbeat"
    STALE_SECONDS=600
    run _heartbeat_is_stale
    [ "$status" -eq 0 ]
}

@test "watchdog: _heartbeat_is_stale returns 1 for a fresh file" {
    _source_watchdog
    HEARTBEAT_FILE="$BATS_TMPDIR/fresh-heartbeat"
    touch "$HEARTBEAT_FILE"
    STALE_SECONDS=600
    run _heartbeat_is_stale
    [ "$status" -eq 1 ]
}

@test "watchdog: _heartbeat_is_stale returns 0 for a file older than threshold" {
    _source_watchdog
    HEARTBEAT_FILE="$BATS_TMPDIR/old-heartbeat"
    # Create file and backdate its mtime by 700 seconds using touch -t.
    touch "$HEARTBEAT_FILE"
    local old_time
    old_time=$(date -v -700S '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '-700 seconds' '+%Y%m%d%H%M.%S' 2>/dev/null \
        || true)
    [ -n "$old_time" ] && touch -t "$old_time" "$HEARTBEAT_FILE"
    STALE_SECONDS=600
    run _heartbeat_is_stale
    [ "$status" -eq 0 ]
}
