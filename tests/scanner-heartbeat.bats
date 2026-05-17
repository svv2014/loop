#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is updated on every tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    LOOP_LOG_DIR="$(mktemp -d)"
    export LOOP_LOG_DIR
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    # Extract both helper functions from scanner.sh without sourcing the whole file.
    eval "$(awk '/^_scanner_heartbeat\(\)/{p=1} p{print} p && /^\}$/{exit}' \
        "$REPO_ROOT/scanner/scanner.sh")"
    eval "$(awk '/^_scanner_check_log\(\)/{p=1} p{print} p && /^\}$/{exit}' \
        "$REPO_ROOT/scanner/scanner.sh")"
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

@test "_scanner_heartbeat: writes PID to heartbeat file" {
    DRY_RUN=false
    _scanner_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
    content=$(cat "$HEARTBEAT_FILE")
    # Must be a positive integer (the PID)
    [[ "$content" =~ ^[0-9]+$ ]]
}

@test "_scanner_heartbeat: skipped in dry-run mode" {
    DRY_RUN=true
    _scanner_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_heartbeat: updates mtime on every call" {
    DRY_RUN=false
    _scanner_heartbeat
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    _scanner_heartbeat
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_check_log: no-op when LOG_FILE is writable" {
    LOG_FILE="$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOG_FILE"
    # Should succeed without side effects
    _scanner_check_log
}

@test "_scanner_check_log: no-op when LOG_FILE is unset" {
    LOG_FILE=""
    _scanner_check_log
}
