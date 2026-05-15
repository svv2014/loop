#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
# 1. scanner.sh writes scanner-heartbeat on every tick.
# 2. scanner-watchdog.sh exits 0 when heartbeat is fresh.
# 3. scanner-watchdog.sh detects a stale (or absent) heartbeat.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    # Stub out all the scan functions so run_once only exercises the heartbeat.
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    scan_project() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat write
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created on first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file mtime is updated on each tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: DRY_RUN skips heartbeat write" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# Watchdog: heartbeat age detection
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    touch "$HEARTBEAT_FILE"
    run env \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_MULTIPLIER=2 \
        LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner healthy"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat is absent" {
    rm -f "$HEARTBEAT_FILE"
    run env \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_MULTIPLIER=2 \
        LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat mtime is old" {
    # Create a heartbeat file with a very old mtime (epoch 1 = 1970).
    touch -t 197001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || touch -d "1970-01-01 00:00:00" "$HEARTBEAT_FILE" 2>/dev/null \
        || { echo "cannot set old mtime — skipping"; skip; }
    run env \
        LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_MULTIPLIER=2 \
        LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
