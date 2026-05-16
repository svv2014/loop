#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is written on every scanner tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source scanner functions (same awk extraction as scanner.bats).
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
    touch "$LOG_FILE"

    DRY_RUN=false
    ONCE=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub out everything that does real work in run_once.
    log() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "heartbeat file is created on first tick" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "heartbeat file contains a unix timestamp" {
    run_once
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    local ts
    ts=$(cat "$hb")
    # timestamp must be numeric and recent (within the last 60 seconds)
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local age=$(( now - ts ))
    [ "$age" -ge 0 ]
    [ "$age" -lt 60 ]
}

@test "heartbeat file is updated on subsequent ticks" {
    run_once
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    local ts1
    ts1=$(cat "$hb")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "$hb")
    # second tick must be >= first (clock monotonically increases)
    [ "$ts2" -ge "$ts1" ]
}

@test "heartbeat is NOT written in dry-run mode" {
    DRY_RUN=true
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ ! -f "$hb" ]
}

@test "watchdog.sh script exists and passes bash -n" {
    bash -n "$REPO_ROOT/scanner/watchdog.sh"
}

@test "watchdog.sh --dry-run prints no-action message when heartbeat is fresh" {
    # Write a fresh heartbeat.
    printf '%s\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"
    # Very high threshold ensures fresh heartbeat is never stale.
    export LOOP_SCANNER_STALE_THRESHOLD=99999
    run "$REPO_ROOT/scanner/watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

@test "watchdog.sh --dry-run reports stale heartbeat and would-kill message" {
    # Write a heartbeat with a timestamp 2000 seconds in the past.
    local past=$(( $(date +%s) - 2000 ))
    printf '%s\n' "$past" > "$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a fake lock file with a PID that does not exist.
    printf '99999999\n' > /tmp/loop-scanner.lock
    export LOOP_SCANNER_STALE_THRESHOLD=900
    run "$REPO_ROOT/scanner/watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
    rm -f /tmp/loop-scanner.lock
}
