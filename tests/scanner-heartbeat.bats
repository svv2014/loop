#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify that scanner-heartbeat is written on every tick
# and that scanner-watchdog.sh detects stale/fresh heartbeats correctly.

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

    # Source scanner.sh function definitions only (stop before acquire_lock).
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

    # Override paths
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence noisy helpers
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    loop_project_is_paused() { return 1; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat written by run_once
# ---------------------------------------------------------------------------

@test "run_once: writes scanner-heartbeat file to LOOP_LOG_DIR" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]

    run_once

    [ -f "$hb" ]
}

@test "run_once: heartbeat file contains a numeric epoch timestamp" {
    run_once

    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    local ts
    ts=$(cat "$hb")
    # Must be a non-empty string of digits only
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "run_once: heartbeat mtime is updated on each call" {
    run_once

    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)

    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat is NOT written in dry-run mode" {
    DRY_RUN=true
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]

    run_once

    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: healthy and stale detection
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 and prints healthy when heartbeat is fresh" {
    # Write a heartbeat with current epoch (age = 0s)
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "scanner-watchdog: detects stale heartbeat in dry-run and prints warning" {
    # Write a heartbeat with a timestamp far in the past (2 hours ago)
    local old_ts=$(( $(date +%s) - 7200 ))
    printf '%s\n' "$old_ts" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Force mtime to match the old timestamp
    touch -t "$(date -r "$old_ts" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$old_ts" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
        "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]] || [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog: detects absent heartbeat as stale" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wedged"* ]] || [[ "$output" == *"WARN"* ]]
}
