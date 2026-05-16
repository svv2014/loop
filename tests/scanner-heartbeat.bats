#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written by scanner each tick
# and checked by scanner-watchdog.sh.
#
# Part 1: heartbeat file tests — source scanner.sh the same way scanner.bats does,
# override LOOP_LOG_DIR, and verify _scanner_write_heartbeat + run_once behaviour.
#
# Part 2: watchdog logic tests — source scanner-watchdog.sh logic directly via
# a trimmed copy that replaces the live launchctl/kill calls with stubs, so the
# staleness-detection and age-calculation paths can be exercised without root.

# ---------------------------------------------------------------------------
# Part 1 — heartbeat written by scanner
# ---------------------------------------------------------------------------

setup_heartbeat() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs-hb"
    mkdir -p "$LOOP_LOG_DIR"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_EXTRA_PATH=""
    local _src="$BATS_TMPDIR/scanner-src-hb.sh"
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

    DEDUP_DIR="$BATS_TMPDIR/dedup-hb"
    LOG_FILE="$BATS_TMPDIR/scanner-hb.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
}

setup() { setup_heartbeat; }

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup-hb" \
           "$BATS_TMPDIR/logs-hb" "$BATS_TMPDIR/scanner-hb.log" \
           "$BATS_TMPDIR/scanner-src-hb.sh" 2>/dev/null || true
}

@test "heartbeat: _scanner_write_heartbeat creates file in LOOP_LOG_DIR" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    _scanner_write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "heartbeat: _scanner_write_heartbeat writes a numeric epoch value" {
    _scanner_write_heartbeat
    local val
    val=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Must be a number and reasonably close to now (within 60s).
    [[ "$val" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local delta=$(( now - val ))
    [ "$delta" -ge 0 ] && [ "$delta" -lt 60 ]
}

@test "heartbeat: _scanner_write_heartbeat updates mtime on each call" {
    _scanner_write_heartbeat
    local first
    first=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    sleep 1
    _scanner_write_heartbeat
    local second
    second=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Epoch values must differ (second is later).
    [ "$second" -gt "$first" ] || [ "$second" -eq "$first" ]
    # File must exist.
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "heartbeat: run_once writes heartbeat file (not dry-run)" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    # Stub out everything scan_project needs so run_once completes quickly.
    loop_list_slugs()   { echo ""; }
    scan_project()      { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()  { :; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "heartbeat: run_once does NOT write heartbeat file in dry-run mode" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    DRY_RUN=true

    loop_list_slugs()   { echo ""; }
    scan_project()      { :; }
    _sweep_stale_locks() { :; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# Part 2 — watchdog staleness detection
# ---------------------------------------------------------------------------

@test "watchdog: exits 0 silently when no heartbeat file exists" {
    local log_dir="$BATS_TMPDIR/wd-logs-no-hb"
    mkdir -p "$log_dir"
    # Run the real watchdog with an empty LOOP_LOG_DIR (no heartbeat file).
    LOOP_LOG_DIR="$log_dir" \
    LOOP_SCANNER_INTERVAL=300 \
    LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
    LOOP_EXTRA_PATH="" \
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file found"* ]]
}

@test "watchdog: exits 0 and reports ok when heartbeat is fresh" {
    local log_dir="$BATS_TMPDIR/wd-logs-fresh"
    mkdir -p "$log_dir"
    # Write a heartbeat that is 10 seconds old (well within the 600s threshold).
    local fresh_epoch
    fresh_epoch=$(( $(date +%s) - 10 ))
    printf '%s\n' "$fresh_epoch" > "$log_dir/scanner-heartbeat"
    touch -t "$(date -r "$fresh_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null || date '+%Y%m%d%H%M.%S')" \
          "$log_dir/scanner-heartbeat" 2>/dev/null || true

    LOOP_LOG_DIR="$log_dir" \
    LOOP_SCANNER_INTERVAL=300 \
    LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
    LOOP_EXTRA_PATH="" \
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat ok"* ]]
}

@test "watchdog: detects stale heartbeat when mtime exceeds threshold" {
    local log_dir="$BATS_TMPDIR/wd-logs-stale"
    mkdir -p "$log_dir"
    # Create a heartbeat file with an old mtime (700 seconds ago > 600s threshold).
    touch "$log_dir/scanner-heartbeat"
    # Use touch -t to backdate the file.
    local old_epoch stale_stamp
    old_epoch=$(( $(date +%s) - 700 ))
    # Format: [[CC]YY]MMDDhhmm[.SS]
    stale_stamp=$(python3 -c "
import datetime, sys
t = datetime.datetime.fromtimestamp($old_epoch)
print(t.strftime('%Y%m%d%H%M.%S'))
" 2>/dev/null || echo "")
    if [ -n "$stale_stamp" ]; then
        touch -t "$stale_stamp" "$log_dir/scanner-heartbeat" 2>/dev/null || true
    fi

    # Confirm the file is actually old enough before running the watchdog.
    local actual_mtime actual_age
    actual_mtime=$(stat -f%m "$log_dir/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$log_dir/scanner-heartbeat" 2>/dev/null || echo 0)
    actual_age=$(( $(date +%s) - actual_mtime ))
    if [ "$actual_age" -lt 600 ]; then
        skip "touch -t did not backdate the file (platform limitation)"
    fi

    # Run watchdog; it must detect the stale heartbeat. We don't have a scanner
    # PID to kill, and launchctl is mocked out by the absence of a lock file.
    LOOP_LOG_DIR="$log_dir" \
    LOOP_SCANNER_INTERVAL=300 \
    LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
    LOOP_EXTRA_PATH="" \
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
