#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written on every tick.
#
# Verifies that scanner.sh writes ${LOOP_LOG_DIR}/scanner-heartbeat on each
# run_once() call, and that scanner-watchdog.sh detects a stale file and
# kills a wedged scanner PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner functions (same approach as scanner.bats).
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

    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    log() { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs()    { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat written by _write_heartbeat / run_once
# ---------------------------------------------------------------------------

@test "_write_heartbeat: creates heartbeat file in LOOP_LOG_DIR" {
    rm -f "$HEARTBEAT_FILE"
    _write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_write_heartbeat: file contains a unix timestamp (integer)" {
    _write_heartbeat
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Must be a non-empty integer string
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "_write_heartbeat: updates mtime on consecutive calls" {
    _write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
          || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
          || echo 0)

    sleep 1
    _write_heartbeat

    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
          || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null \
          || echo 0)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat file written during a tick" {
    rm -f "$HEARTBEAT_FILE"
    # Stub out everything that run_once would otherwise call.
    _write_heartbeat() { date +%s > "$HEARTBEAT_FILE"; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    loop_list_slugs()    { :; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat NOT written in dry-run mode" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=true
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    loop_list_slugs()    { :; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with 'healthy' when heartbeat is fresh" {
    date +%s > "$HEARTBEAT_FILE"
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and reports WARN" {
    # Back-date the heartbeat file well beyond the default 600 s threshold.
    date +%s > "$HEARTBEAT_FILE"
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M' -d '-60 minutes')" \
        "$HEARTBEAT_FILE" 2>/dev/null || \
    touch -d "1970-01-01 00:00:00" "$HEARTBEAT_FILE" 2>/dev/null || true

    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}

@test "scanner-watchdog: --dry-run does not kill any process" {
    date +%s > "$HEARTBEAT_FILE"
    touch -d "1970-01-01 00:00:00" "$HEARTBEAT_FILE" 2>/dev/null || \
    touch -t "197001010000" "$HEARTBEAT_FILE" 2>/dev/null || true

    # Write our own PID as a fake scanner lock — watchdog must NOT kill us.
    echo "$$" > /tmp/loop-scanner.lock

    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run

    rm -f /tmp/loop-scanner.lock
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    # We are still alive.
    kill -0 "$$"
}
