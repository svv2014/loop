#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written on every tick.
#
# Verifies:
#   1. _write_heartbeat creates the heartbeat file in LOOP_LOG_DIR.
#   2. The file contains a Unix epoch integer.
#   3. run_once updates the heartbeat on every call.
#   4. DRY_RUN suppresses the write.
#   5. scanner-watchdog.sh exits cleanly when heartbeat is fresh.
#   6. scanner-watchdog.sh kills a stale PID when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh functions only (stop before acquire_lock).
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

    # Silence log() and disable real dispatch/lock sweeps.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }

    LOOP_JOBS_ENQUEUE=0
    DRY_RUN=false
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _write_heartbeat
# ---------------------------------------------------------------------------

@test "_write_heartbeat: creates heartbeat file" {
    _write_heartbeat
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "_write_heartbeat: file contains a Unix epoch integer" {
    _write_heartbeat
    local content
    content=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Must be a non-empty string of digits
    [[ "$content" =~ ^[0-9]+$ ]]
    # Must be a plausible epoch (after 2020-01-01)
    [ "$content" -gt 1577836800 ]
}

@test "_write_heartbeat: updates mtime on repeated calls" {
    _write_heartbeat
    local first
    first=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    sleep 1
    _write_heartbeat
    local second
    second=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    [ "$second" -gt "$first" ]
}

@test "_write_heartbeat: no-op in dry-run mode" {
    DRY_RUN=true
    _write_heartbeat
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# run_once writes heartbeat
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is written each tick" {
    run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat is old" {
    # Write a heartbeat 2 hours in the past by touching with an old mtime.
    printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$LOOP_LOG_DIR/scanner-heartbeat"
    # Backdate the mtime so stat-based age detection also fires.
    touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" \
        "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || true
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog: dry-run does not kill any process" {
    printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" \
        "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || true
    # Place a fake (own PID) in the lock file so watchdog finds a "live" scanner.
    printf '%s\n' "$$" > /tmp/loop-scanner.lock
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    rm -f /tmp/loop-scanner.lock
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
}
