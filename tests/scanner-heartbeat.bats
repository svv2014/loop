#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes a liveness heartbeat file on every tick.
#
# Sourcing strategy: same awk extraction used in scanner.bats — strip SCRIPT_DIR,
# LOOP_ROOT, the arg-parsing for-loop, and stop before acquire_lock.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    export LOOP_EXTRA_PATH=""
    mkdir -p "$LOOP_LOG_DIR"

    local _src="$BATS_TMPDIR/scanner-hb-src.sh"
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

    # Stub out everything run_once calls besides the heartbeat write.
    log() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { printf ''; }
    scan_project() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

@test "run_once: writes scanner-heartbeat file to LOOP_LOG_DIR" {
    DRY_RUN=false
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat content is a unix timestamp (digits only)" {
    DRY_RUN=false
    run_once
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "run_once: heartbeat is NOT written in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat mtime is updated on each tick" {
    DRY_RUN=false
    run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)

    # Ensure at least one second elapses between ticks.
    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}
