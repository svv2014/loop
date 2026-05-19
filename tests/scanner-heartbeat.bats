#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat (issue #413).
#
# Verifies:
#   1. run_once() writes the heartbeat file on every tick (non-dry-run).
#   2. Dry-run mode does NOT write the heartbeat file.
#   3. restart-scanner-if-stale.sh exits 0 and reports healthy when heartbeat is fresh.
#   4. restart-scanner-if-stale.sh exits 0 when heartbeat file is absent.
#   5. restart-scanner-if-stale.sh detects stale heartbeat and reports "wedged".
#   6. restart-scanner-if-stale.sh dry-run does not kill the scanner PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"

    # Source scanner.sh function definitions only (stop before acquire_lock).
    # Strip arg-parsing loop so bats-injected $@ doesn't confuse flag parsing.
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

    # Override variables scanner.sh sets post-source.
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub out side-effectful helpers.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { return 0; }
    loop_list_slugs() { echo ""; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file managed by run_once
# ---------------------------------------------------------------------------

@test "run_once: writes heartbeat file on each tick (non-dry-run)" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=false
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: updates heartbeat mtime on repeated ticks" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=false
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: dry-run does NOT write heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale: exits 0 when heartbeat file is absent" {
    rm -f "$HEARTBEAT_FILE"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"has not ticked yet"* ]]
}

@test "restart-scanner-if-stale: reports healthy when heartbeat is fresh" {
    touch "$HEARTBEAT_FILE"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_STALE_THRESHOLD=900 \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "restart-scanner-if-stale: detects stale heartbeat and reports wedged" {
    touch "$HEARTBEAT_FILE"
    # Backdate by 20 minutes so age > default 900s threshold.
    touch -t "$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d '20 minutes ago' +%Y%m%d%H%M.%S)" "$HEARTBEAT_FILE"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_STALE_THRESHOLD=900 \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]]
}

@test "restart-scanner-if-stale: dry-run does not kill live PID" {
    touch "$HEARTBEAT_FILE"
    touch -t "$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d '20 minutes ago' +%Y%m%d%H%M.%S)" "$HEARTBEAT_FILE"

    # Plant own PID so the script finds a live process.
    local lock_file="/tmp/loop-scanner.lock"
    echo "$$" > "$lock_file"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_STALE_THRESHOLD=900 \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run

    rm -f "$lock_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
}
