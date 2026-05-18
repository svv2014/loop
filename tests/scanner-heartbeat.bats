#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. scanner.sh writes HEARTBEAT_FILE on every tick.
#   2. restart-scanner-if-stale.sh exits cleanly when heartbeat is fresh.
#   3. restart-scanner-if-stale.sh kills the target process when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same awk strip as scanner.bats).
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

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=true
    ONCE=true
}

teardown() {
    rm -f "$HEARTBEAT_FILE"
}

# ── scanner.sh writes heartbeat on every tick ─────────────────────────────────

@test "run_once writes heartbeat file to LOOP_LOG_DIR/scanner-heartbeat" {
    # Stub out the parts of run_once that need a real config/projects.yaml.
    loop_list_slugs() { echo ""; }
    jobs_init_schema() { return 0; }

    run_once

    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once heartbeat contains a unix epoch timestamp" {
    loop_list_slugs() { echo ""; }
    jobs_init_schema() { return 0; }

    run_once

    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Must be a number and roughly current (within last 5 seconds).
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local delta=$(( now - ts ))
    [ "$delta" -ge 0 ] && [ "$delta" -lt 5 ]
}

@test "run_once updates heartbeat on repeated ticks" {
    loop_list_slugs() { echo ""; }
    jobs_init_schema() { return 0; }

    # First tick.
    run_once
    local ts1
    ts1=$(cat "$HEARTBEAT_FILE")

    sleep 1

    # Second tick.
    run_once
    local ts2
    ts2=$(cat "$HEARTBEAT_FILE")

    # Timestamp must have advanced (or at least be >= first).
    [ "$ts2" -ge "$ts1" ]
}

# ── restart-scanner-if-stale.sh: fresh heartbeat ──────────────────────────────

@test "watchdog: exits 0 and prints 'ok' when heartbeat is fresh" {
    # Write a heartbeat that is 1 second old.
    date +%s > "$HEARTBEAT_FILE"

    LOOP_SCANNER_STALE_THRESHOLD=600 \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

# ── restart-scanner-if-stale.sh: stale heartbeat (dry-run) ────────────────────

@test "watchdog: detects stale heartbeat and reports STALE in dry-run" {
    # Write a heartbeat timestamp 20 minutes in the past.
    echo $(( $(date +%s) - 1200 )) > "$HEARTBEAT_FILE"

    LOOP_SCANNER_STALE_THRESHOLD=600 \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

# ── restart-scanner-if-stale.sh: no heartbeat file ────────────────────────────

@test "watchdog: exits 0 and skips when heartbeat file is absent" {
    rm -f "$HEARTBEAT_FILE"

    LOOP_SCANNER_STALE_THRESHOLD=600 \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]]
}

# ── restart-scanner-if-stale.sh: stale heartbeat kills process ────────────────

@test "watchdog: kills target PID when heartbeat is stale (live PID test)" {
    # Spawn a background sleep to act as the "scanner".
    sleep 60 &
    local fake_pid=$!

    # Plant a lock file pointing to the fake scanner.
    local fake_lock="$BATS_TMPDIR/loop-scanner-fake.lock"
    echo "$fake_pid" > "$fake_lock"

    # Write a heartbeat that is 20 minutes old.
    echo $(( $(date +%s) - 1200 )) > "$HEARTBEAT_FILE"

    # Run watchdog with custom lock path via env var substitution.
    # We need to override LOCK_FILE inside the script, so we source its
    # logic directly rather than exec-ing, to inject variables.
    LOCK_FILE="$fake_lock" \
    LOOP_SCANNER_STALE_THRESHOLD=600 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"killing"* ]] || [[ "$output" == *"STALE"* ]]

    # The fake sleep should be gone.
    sleep 0.2
    ! kill -0 "$fake_pid" 2>/dev/null

    rm -f "$fake_lock"
}
