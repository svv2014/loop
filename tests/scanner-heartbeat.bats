#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written on every scanner tick.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR"
    export HEARTBEAT_FILE="$BATS_TMPDIR/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"
}

teardown() {
    rm -f "$HEARTBEAT_FILE"
}

@test "scanner.sh writes scanner-heartbeat on each tick (source inspection)" {
    grep -q 'scanner-heartbeat' "$REPO_ROOT/scanner/scanner.sh"
    grep -q 'LOOP_LOG_DIR.*scanner-heartbeat\|scanner-heartbeat.*LOOP_LOG_DIR' "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner-watchdog.sh exists and is executable" {
    [ -f "$REPO_ROOT/scanner/scanner-watchdog.sh" ]
    [ -x "$REPO_ROOT/scanner/scanner-watchdog.sh" ]
}

@test "scanner-watchdog.sh exits cleanly when heartbeat file is missing" {
    # No heartbeat file — watchdog should log a warning and exit 0 (not crash).
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]] || [[ "$output" == *"not have started"* ]]
}

@test "scanner-watchdog.sh reports OK when heartbeat is fresh" {
    # Write a current timestamp — age will be ~0s, well below threshold.
    printf '%s\n' "$(date +%s)" > "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "scanner-watchdog.sh detects stale heartbeat and reports STALE" {
    # Back-date mtime by 3 hours (10800s). The watchdog threshold is
    # 2 × LOOP_SCANNER_INTERVAL (minimum 600s, typically 3600s); 10800s
    # exceeds any reasonable configured value.
    printf '%s\n' "0" > "$HEARTBEAT_FILE"
    local stale_ts=$(( $(date +%s) - 10800 ))
    python3 -c "import os; os.utime('$HEARTBEAT_FILE', ($stale_ts, $stale_ts))"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
