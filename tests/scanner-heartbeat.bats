#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat (#413).
#
# Verifies that _write_heartbeat creates / updates the heartbeat file on every
# tick, and that scanner-watchdog.sh exits cleanly when the file is fresh and
# detects staleness when it is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Minimal mock-gh so env.sh can source workflow.sh without side effects.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export LOOP_EXTRA_PATH=""

    # Source scanner function definitions (same strategy as scanner.bats).
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

    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    DRY_RUN=false

    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/bin" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _write_heartbeat
# ---------------------------------------------------------------------------

@test "_write_heartbeat: creates heartbeat file when absent" {
    rm -f "$HEARTBEAT_FILE"
    _write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_write_heartbeat: updates mtime on every call" {
    _write_heartbeat
    local t1
    t1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    # Wait at least 1 second so mtime resolution shows a difference.
    sleep 1.1
    _write_heartbeat
    local t2
    t2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$t2" -gt "$t1" ]
}

@test "_write_heartbeat: writes current timestamp in readable form" {
    _write_heartbeat
    local content
    content=$(cat "$HEARTBEAT_FILE")
    # Matches YYYY-MM-DD HH:MM:SS
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "_write_heartbeat: no-op in dry-run mode" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    _write_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
    DRY_RUN=false
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — integration tests
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat (age ≈ 0 s).
    date '+%Y-%m-%d %H:%M:%S' > "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and reports wedge" {
    # Set LOOP_SCANNER_INTERVAL=60 so threshold=120s; file is 300s old → stale.
    export LOOP_SCANNER_INTERVAL=60

    touch "$HEARTBEAT_FILE"
    python3 -c "
import os, time
path = '$HEARTBEAT_FILE'
old = time.time() - 300
os.utime(path, (old, old))
"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
    unset LOOP_SCANNER_INTERVAL
}

@test "scanner-watchdog: treats missing heartbeat as stale" {
    export LOOP_SCANNER_INTERVAL=60
    rm -f "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]]
    unset LOOP_SCANNER_INTERVAL
}
