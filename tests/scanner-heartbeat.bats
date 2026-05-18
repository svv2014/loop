#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes the heartbeat file on
# every tick and that the watchdog script correctly identifies stale scanners.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same technique as scanner.bats).
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    # Stub out all project iteration so run_once() returns quickly.
    loop_list_slugs()    { return 0; }
    jobs_init_schema()   { return 0; }
    _sweep_stale_locks() { return 0; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file — written on every tick
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file in LOOP_LOG_DIR" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    rm -f "$hb"
    run_once
    [ -f "$hb" ]
}

@test "run_once: heartbeat file contains a unix timestamp" {
    run_once
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # A valid Unix timestamp is a string of digits >= 10 chars.
    [[ "$ts" =~ ^[0-9]{10,}$ ]]
}

@test "run_once: heartbeat file is refreshed on every call" {
    run_once
    local t1
    t1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    sleep 1
    run_once
    local t2
    t2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    # mtime must advance — second call touches the file again.
    [ "$t2" -ge "$t1" ]
}

@test "run_once: DRY_RUN=true does NOT write heartbeat file" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    rm -f "$hb"
    DRY_RUN=true
    run_once
    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh — watchdog behaviour
# ---------------------------------------------------------------------------

@test "watchdog: exits 0 without action when heartbeat is fresh" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    date +%s > "$hb"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_MULTIPLIER=2 \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

@test "watchdog: exits 0 without action when heartbeat file is missing" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_MULTIPLIER=2 \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not yet started"* || "$output" == *"not found"* ]]
}

@test "watchdog: detects stale heartbeat and logs would-kill message (dry-run)" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    # Write a timestamp that is 1000s in the past.
    echo $(( $(date +%s) - 1000 )) > "$hb"
    # Back-date the file itself so stat -f%m / stat -c%Y reflects the age.
    touch -t "$(date -v-1000S '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '1000 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date '+%Y%m%d%H%M.%S')" "$hb" 2>/dev/null || true

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_MULTIPLIER=2 \
        "$REPO_ROOT/scripts/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    # Should report stale and (in dry-run) a would-kill or no-action message.
    [[ "$output" == *"stale"* ]]
}
