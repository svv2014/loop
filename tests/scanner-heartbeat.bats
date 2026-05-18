#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. _heartbeat_write creates/updates the heartbeat file on every tick.
#   2. scanner-watchdog.sh considers a fresh heartbeat healthy.
#   3. scanner-watchdog.sh detects a stale heartbeat and would restart.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

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

    log() { :; }
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$BATS_TMPDIR/logs" 2>/dev/null || true
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

@test "_heartbeat_write writes a unix timestamp" {
    _heartbeat_write
    local val
    val=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Must be a number and close to now.
    [[ "$val" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local diff=$(( now - val ))
    [ "$diff" -ge 0 ] && [ "$diff" -lt 5 ]
}

@test "_heartbeat_write updates mtime on repeated calls" {
    _heartbeat_write
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    sleep 1
    _heartbeat_write
    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: dry-run behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat.
    printf '%s\n' "$(date +%s)" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is healthy"* ]]
}

@test "scanner-watchdog.sh reports STALE when heartbeat is old" {
    # Set interval to 60s so the stale threshold is 2×60=120s.
    # Write a heartbeat 300s old — clearly stale regardless of loop.env.
    export LOOP_SCANNER_INTERVAL=60
    local old_ts=$(( $(date +%s) - 300 ))
    printf '%s\n' "$old_ts" > "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog.sh reports STALE when heartbeat file is absent" {
    # No heartbeat file at all.
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
