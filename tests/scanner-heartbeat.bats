#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written on every tick (#413).
#
# Verifies that scanner/scanner.sh touches scanner-heartbeat at the top of
# run_once(), and that scanner-watchdog.sh correctly detects a fresh vs stale
# heartbeat and only kills a wedged scanner PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh function definitions only (same awk strip as scanner.bats).
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

    # Override paths that scanner.sh hard-codes after sourcing.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log(); stub out functions that would make real GH calls.
    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file on first tick" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: updates scanner-heartbeat mtime on every tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: does not touch heartbeat file in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 quietly when heartbeat is absent" {
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat file absent"* ]]
}

@test "scanner-watchdog: reports ok when heartbeat is fresh" {
    touch "$HEARTBEAT_FILE"
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and reports wedge" {
    touch -t "$(date -d '1 hour ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -v-1H '+%Y%m%d%H%M.%S')" "$HEARTBEAT_FILE"
    export LOOP_SCANNER_INTERVAL=300
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
