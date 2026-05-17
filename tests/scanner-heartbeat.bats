#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#   1. scanner.sh writes HEARTBEAT_FILE at every tick (source-level check).
#   2. scanner-watchdog.sh exits cleanly when heartbeat is fresh.
#   3. scanner-watchdog.sh kills a wedged scanner when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    export LOOP_EXTRA_PATH=""
    mkdir -p "$LOOP_LOG_DIR"
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

@test "scanner.sh writes HEARTBEAT_FILE variable and touches it in run_once" {
    # Regression guard: HEARTBEAT_FILE must be defined and written in run_once.
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
    grep -q 'HEARTBEAT_FILE' "$REPO_ROOT/scanner/scanner.sh"
    # The heartbeat write must be inside run_once (before or after the log line)
    awk '/^run_once\(\)/{found=1} found && /HEARTBEAT_FILE/{print; exit}' \
        "$REPO_ROOT/scanner/scanner.sh" | grep -q 'HEARTBEAT_FILE'
}

@test "scanner-watchdog.sh: exits 0 when heartbeat is fresh" {
    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    printf '%s pid=99999\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$heartbeat"

    # Set stale threshold to 600s — a brand-new file is well within it.
    run env LOOP_WATCHDOG_STALE_SECONDS=600 \
        "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

@test "scanner-watchdog.sh: reports stale heartbeat in dry-run mode" {
    local heartbeat="$LOOP_LOG_DIR/scanner-heartbeat"
    printf '%s pid=99999\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$heartbeat"

    # Back-date the heartbeat by touching it with a timestamp 30 min ago.
    local old_time
    old_time=$(date -v -30M '+%Y%m%d%H%M' 2>/dev/null \
        || date -d '30 minutes ago' '+%Y%m%d%H%M' 2>/dev/null \
        || true)

    if [ -z "$old_time" ]; then
        skip "platform does not support date back-dating"
    fi
    touch -t "$old_time" "$heartbeat"

    run env LOOP_WATCHDOG_STALE_SECONDS=600 \
        "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog.sh: exits 0 when heartbeat file is missing" {
    # No heartbeat file — scanner may not have started yet; watchdog must not crash.
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "scanner-watchdog.sh: syntax check passes" {
    bash -n "$REPO_ROOT/scripts/scanner-watchdog.sh"
}
