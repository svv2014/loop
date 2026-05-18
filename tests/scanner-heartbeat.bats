#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner writes heartbeat on every tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/loop-logs-$$"
    mkdir -p "$LOOP_LOG_DIR"
    # Extract _write_heartbeat from scanner.sh so we can unit-test it in isolation.
    eval "$(awk '/^HEARTBEAT_FILE=/{print} /^_write_heartbeat\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
        "$REPO_ROOT/scanner/scanner.sh")"
    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

@test "_write_heartbeat: creates heartbeat file" {
    [ ! -f "$HEARTBEAT_FILE" ]
    _write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_write_heartbeat: file contains a timestamp" {
    _write_heartbeat
    content=$(cat "$HEARTBEAT_FILE")
    # Must look like YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "_write_heartbeat: updates mtime on repeated calls" {
    _write_heartbeat
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    _write_heartbeat
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}
