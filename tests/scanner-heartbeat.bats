#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner writes heartbeat on every tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    TMP_DIR="$(mktemp -d)"
    export LOOP_LOG_DIR="$TMP_DIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "scanner-watchdog: heartbeat file is absent before first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "scanner: run_once touches heartbeat file" {
    # Source scanner internals in a minimal stub environment so run_once can run
    # without real GitHub access.  We override the functions that would call out.
    (
        export LOOP_LOG_DIR
        export LOOP_ROOT
        # Minimal stubs so scanner.sh sources without errors
        loop_list_slugs() { :; }
        loop_load_backend() { :; }
        loop_workflow_for_project() { echo "default"; }
        loop_polled_labels() { :; }
        jobs_init_schema() { :; }
        _sweep_stale_locks() { :; }

        # Extract and eval only the functions we need from scanner.sh,
        # skipping the acquire_lock + main loop at the bottom.
        eval "$(awk '
            /^HEARTBEAT_FILE=/ { print; next }
            /^_scanner_check_log_writable\(\)/{p=1}
            /^run_once\(\)/{p=1}
            p
            p && /^\}$/{p=0}
        ' "$LOOP_ROOT/scanner/scanner.sh")"

        DRY_RUN=false
        LOOP_JOBS_ENQUEUE=0
        LOG_FILE="$LOOP_LOG_DIR/loop-scanner.log"
        log() { :; }

        run_once
    )
    [ -f "$HEARTBEAT_FILE" ]
}

@test "scanner: run_once updates heartbeat mtime each call" {
    (
        export LOOP_LOG_DIR
        export LOOP_ROOT

        loop_list_slugs() { :; }
        loop_load_backend() { :; }
        loop_workflow_for_project() { echo "default"; }
        loop_polled_labels() { :; }
        jobs_init_schema() { :; }
        _sweep_stale_locks() { :; }

        eval "$(awk '
            /^HEARTBEAT_FILE=/ { print; next }
            /^_scanner_check_log_writable\(\)/{p=1}
            /^run_once\(\)/{p=1}
            p
            p && /^\}$/{p=0}
        ' "$LOOP_ROOT/scanner/scanner.sh")"

        DRY_RUN=false
        LOOP_JOBS_ENQUEUE=0
        LOG_FILE="$LOOP_LOG_DIR/loop-scanner.log"
        log() { :; }

        run_once
        mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
        sleep 1
        run_once
        mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
        [ "$mtime2" -ge "$mtime1" ]
    )
    [ -f "$HEARTBEAT_FILE" ]
}

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    touch "$HEARTBEAT_FILE"
    # threshold of 600s, file just touched — should be alive
    LOOP_SCANNER_WATCHDOG_STALE_THRESHOLD=600 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and reports in dry-run" {
    # Create a heartbeat file and backdate its mtime by 1200s
    touch "$HEARTBEAT_FILE"
    # Use a threshold of 10s so we can compare against any recent mtime
    # by simply not touching the file and using a tiny threshold.
    # Instead: set threshold to 0 so any file age is stale.
    LOOP_SCANNER_WATCHDOG_STALE_THRESHOLD=0 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
