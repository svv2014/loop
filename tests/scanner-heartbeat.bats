#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file written on every tick (#413).
#
# Verifies:
#   1. scanner.sh defines _update_heartbeat and calls it from run_once.
#   2. _update_heartbeat writes a numeric epoch to HEARTBEAT_FILE.
#   3. scanner-watchdog.sh detects a stale heartbeat (age >= threshold).
#   4. scanner-watchdog.sh reports OK when heartbeat is fresh.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose mock-gh.sh so env.sh / config.sh sourcing doesn't fail.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export LOOP_EXTRA_PATH=""

    # Source scanner function definitions (same approach as scanner.bats).
    local _src="$BATS_TMPDIR/scanner-hb-src.sh"
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
}

teardown() {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
}

# ---------------------------------------------------------------------------
# Structural checks
# ---------------------------------------------------------------------------

@test "scanner.sh defines _update_heartbeat function" {
    grep -q "_update_heartbeat()" "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh calls _update_heartbeat inside run_once" {
    # Confirm the call appears in the run_once body (between run_once() { and next top-level })
    awk '/^run_once\(\)/{found=1} found && /_update_heartbeat/{print; exit}' \
        "$REPO_ROOT/scanner/scanner.sh" | grep -q "_update_heartbeat"
}

# ---------------------------------------------------------------------------
# Behavioural checks
# ---------------------------------------------------------------------------

@test "_update_heartbeat writes epoch to HEARTBEAT_FILE" {
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    DRY_RUN=false
    _update_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
    local val
    val=$(cat "$HEARTBEAT_FILE")
    # Value must be a positive integer (Unix epoch)
    [[ "$val" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    # Must have been written within the last 5 seconds
    [ $(( now - val )) -lt 5 ]
}

@test "_update_heartbeat is a no-op in dry-run mode" {
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    DRY_RUN=true
    _update_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "_update_heartbeat updates mtime on repeated calls" {
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    DRY_RUN=false
    # Write a stale value first.
    echo "1000000" > "$HEARTBEAT_FILE"
    _update_heartbeat
    local val
    val=$(cat "$HEARTBEAT_FILE")
    local now
    now=$(date +%s)
    [ $(( now - val )) -lt 5 ]
}

# ---------------------------------------------------------------------------
# Watchdog detection
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh exists and is executable" {
    [ -x "$REPO_ROOT/scanner/scanner-watchdog.sh" ]
}

@test "scanner-watchdog.sh reports STALE when heartbeat is old" {
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    # Create a file and backdate its mtime to 2 hours ago using touch.
    touch "$HEARTBEAT_FILE"
    touch -t "$(date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
              || date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null)" "$HEARTBEAT_FILE"

    # Run in dry-run mode; output must mention STALE.
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "STALE"
}

@test "scanner-watchdog.sh reports OK when heartbeat is fresh" {
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a fresh heartbeat.
    date +%s > "$HEARTBEAT_FILE"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

@test "scanner-watchdog.sh reports STALE when heartbeat file is absent" {
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "STALE"
}
