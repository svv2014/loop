#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is written on every tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    # Isolated scratch dir for each test.
    export LOOP_LOG_DIR="$BATS_TMPDIR/hb-logdir-$$"
    mkdir -p "$LOOP_LOG_DIR"

    # Extract _write_heartbeat and its dependency variable from scanner.sh.
    eval "$(awk '
        /^HEARTBEAT_FILE=/{print; next}
        /^_write_heartbeat\(\)/{p=1}
        p
        p && /^\}$/{p=0}
    ' "$REPO_ROOT/scanner/scanner.sh")"

    # Default: not in dry-run mode.
    DRY_RUN=false
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

@test "_write_heartbeat: creates heartbeat file" {
    run _write_heartbeat
    [ "$status" -eq 0 ]
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "_write_heartbeat: file contains a valid epoch timestamp" {
    _write_heartbeat
    content=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Must be a string of digits (Unix epoch).
    [[ "$content" =~ ^[0-9]+$ ]]
    now=$(date +%s)
    # Timestamp must be within the last 5 seconds.
    age=$(( now - content ))
    [ "$age" -ge 0 ]
    [ "$age" -lt 5 ]
}

@test "_write_heartbeat: updates mtime on successive calls" {
    _write_heartbeat
    first=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    sleep 1
    _write_heartbeat
    second=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Second timestamp must be >= first (monotonically non-decreasing).
    [ "$second" -ge "$first" ]
}

@test "_write_heartbeat: skips write in dry-run mode" {
    DRY_RUN=true
    _write_heartbeat
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}
