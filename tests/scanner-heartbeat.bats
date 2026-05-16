#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

@test "scanner.sh writes heartbeat file on every tick" {
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
    grep -q 'scanner-heartbeat' "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh writes heartbeat in run_once before sweep" {
    # Heartbeat write must appear before _sweep_stale_locks in run_once so it
    # fires even when the sweep itself is skipped (DRY_RUN=true path omits the
    # heartbeat write but the non-dry path must write it first).
    local src="$REPO_ROOT/scanner/scanner.sh"
    local hb_line sweep_line
    hb_line=$(grep -n 'HEARTBEAT_FILE' "$src" | grep 'date +%s' | head -1 | cut -d: -f1)
    sweep_line=$(grep -n '_sweep_stale_locks' "$src" | grep -v '^#' | tail -1 | cut -d: -f1)
    [ -n "$hb_line" ]
    [ -n "$sweep_line" ]
    [ "$hb_line" -lt "$sweep_line" ]
}

@test "restart-scanner-if-stale.sh exists and is executable" {
    [ -x "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" ]
}

@test "restart-scanner-if-stale.sh passes bash -n syntax check" {
    bash -n "$REPO_ROOT/scripts/restart-scanner-if-stale.sh"
}

@test "restart-scanner-if-stale.sh dry-run: healthy heartbeat logs no restart" {
    date +%s > "$HEARTBEAT_FILE"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    LOOP_SCANNER_STALE_THRESHOLD=600 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

@test "restart-scanner-if-stale.sh dry-run: absent heartbeat triggers restart message" {
    rm -f "$HEARTBEAT_FILE"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    LOOP_SCANNER_STALE_THRESHOLD=600 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}

@test "restart-scanner-if-stale.sh dry-run: stale heartbeat triggers restart message" {
    # Write a heartbeat timestamped far in the past using touch -t
    touch -t 200001010000 "$HEARTBEAT_FILE"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    LOOP_SCANNER_STALE_THRESHOLD=600 \
        run "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog launchd template exists" {
    [ -f "$REPO_ROOT/templates/launchd/com.user.loop-scanner-watchdog.plist.template" ]
}

@test "scanner-watchdog launchd template contains StartInterval 300" {
    grep -q 'StartInterval' "$REPO_ROOT/templates/launchd/com.user.loop-scanner-watchdog.plist.template"
    grep -A1 'StartInterval' "$REPO_ROOT/templates/launchd/com.user.loop-scanner-watchdog.plist.template" \
        | grep -q '300'
}
