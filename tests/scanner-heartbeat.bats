#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#   1. _heartbeat_write creates/updates the heartbeat file on every tick.
#   2. scanner-watchdog.sh considers a fresh heartbeat healthy (exits 0, no restart).
#   3. scanner-watchdog.sh detects a stale heartbeat and would restart.
#   4. scanner-watchdog.sh handles a missing heartbeat file as stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Prevent env.sh from prepending /opt/homebrew/bin and shadowing any mock bin.
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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

    # Silence log() so test output stays clean.
    log() { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _heartbeat_write
# ---------------------------------------------------------------------------

@test "_heartbeat_write creates heartbeat file" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]
    _heartbeat_write
    [ -f "$hb" ]
}

@test "_heartbeat_write writes a unix timestamp close to now" {
    _heartbeat_write
    local val
    val=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    [[ "$val" =~ ^[0-9]+$ ]]
    local now diff
    now=$(date +%s)
    diff=$(( now - val ))
    [ "$diff" -ge 0 ] && [ "$diff" -lt 5 ]
}

@test "_heartbeat_write updates the file on repeated calls" {
    _heartbeat_write
    local v1
    v1=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    sleep 1
    _heartbeat_write
    local v2
    v2=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    [ "$v2" -ge "$v1" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — dry-run behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh exits 0 and reports healthy when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

@test "scanner-watchdog.sh reports STALE when heartbeat epoch is old" {
    # Set interval to 60s → threshold = 120s; write a 300s-old heartbeat.
    export LOOP_SCANNER_INTERVAL=60
    local old_ts=$(( $(date +%s) - 300 ))
    printf '%s\n' "$old_ts" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog.sh reports STALE when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
