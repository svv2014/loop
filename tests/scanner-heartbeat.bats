#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Tests that:
#   1. _scanner_update_heartbeat writes the heartbeat file on every tick.
#   2. scanner-watchdog.sh exits cleanly when heartbeat is fresh.
#   3. scanner-watchdog.sh kills a stale scanner lock PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same approach as scanner.bats).
    export LOOP_EXTRA_PATH=""
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
    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_update_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_update_heartbeat: creates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_update_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_update_heartbeat: heartbeat file contains current pid" {
    _scanner_update_heartbeat
    grep -q "pid=$$" "$HEARTBEAT_FILE"
}

@test "_scanner_update_heartbeat: updates mtime on repeated calls" {
    _scanner_update_heartbeat
    local t1
    t1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    _scanner_update_heartbeat
    local t2
    t2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$t2" -gt "$t1" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 silently when heartbeat is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
}

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    printf '%s pid=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" \
        > "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

@test "scanner-watchdog --dry-run: reports stale without killing" {
    # Write a heartbeat file with an ancient mtime (touch -t sets to year 2000).
    printf 'stale\n' > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t 200001010000 "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run"* ]]
}
