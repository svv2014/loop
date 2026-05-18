#!/usr/bin/env bats
# tests/scanner-watchdog.bats — unit tests for scanner-watchdog.sh and
# the heartbeat file written by scanner.sh on every tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    export LOOP_EXTRA_PATH=""
    mkdir -p "$LOOP_LOG_DIR"

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    LOCK_FILE="/tmp/loop-scanner.lock"

    # Remove stale lock file from previous test runs.
    rm -f "$LOCK_FILE"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Heartbeat — scanner.sh writes it on every tick
# ─────────────────────────────────────────────────────────────────────────────

@test "scanner.sh run_once writes heartbeat file to LOOP_LOG_DIR" {
    # Source scanner definitions (same technique as tests/scanner.bats).
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

    # Stub out everything that would touch GitHub or dispatch handlers.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
    LOOP_JOBS_ENQUEUE=0
    DRY_RUN=false

    run_once

    [ -f "$HEARTBEAT_FILE" ]
    local content
    content=$(cat "$HEARTBEAT_FILE")
    [ -n "$content" ]
    # Content should be a unix epoch (all digits).
    [[ "$content" =~ ^[0-9]+$ ]]
}

@test "scanner.sh run_once skips heartbeat write in DRY_RUN mode" {
    local _src="$BATS_TMPDIR/scanner-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        awk '
            /^SCRIPT_DIR=/           { next }
            /^LOOP_ROOT=/            { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=true"; print "ONCE=true"; next }
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
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
    LOOP_JOBS_ENQUEUE=0
    DRY_RUN=true

    run_once

    [ ! -f "$HEARTBEAT_FILE" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Watchdog — scanner-watchdog.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "watchdog: exits cleanly when no heartbeat file exists" {
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file"* ]]
}

@test "watchdog: reports ok when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "$HEARTBEAT_FILE"
    # Use a very large threshold so a fresh file is always under it.
    LOOP_WATCHDOG_STALE_SECONDS=99999 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat ok"* ]]
}

@test "watchdog: dry-run does not kill any process" {
    printf '%s\n' "$(date +%s)" > "$HEARTBEAT_FILE"
    # Write a lock file pointing to a real (harmless) PID — our own shell.
    printf '%s\n' "$$" > "$LOCK_FILE"

    LOOP_WATCHDOG_STALE_SECONDS=0 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    # Our process must still be alive.
    kill -0 "$$"
}

@test "watchdog: stale heartbeat with no lock file exits cleanly" {
    printf '%s\n' "$(date +%s)" > "$HEARTBEAT_FILE"
    rm -f "$LOCK_FILE"

    LOOP_WATCHDOG_STALE_SECONDS=0 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"no lock file"* ]]
}
