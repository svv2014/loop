#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written every scanner tick.

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
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _write_heartbeat
# ---------------------------------------------------------------------------

@test "_write_heartbeat: creates heartbeat file in LOOP_LOG_DIR" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    _write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_write_heartbeat: heartbeat file contains a unix epoch timestamp" {
    _write_heartbeat
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Epoch seconds since 2020-01-01 — just a sanity bound.
    [ "$ts" -gt 1577836800 ] 2>/dev/null
}

@test "_write_heartbeat: updates mtime on every call" {
    _write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    sleep 1
    _write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_write_heartbeat: is no-op in dry-run mode" {
    DRY_RUN=true
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    _write_heartbeat
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat file exists after a tick" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    # Stub everything run_once calls so the tick completes without real I/O.
    loop_list_slugs()    { return 0; }
    jobs_init_schema()   { return 0; }
    _sweep_stale_locks() { return 0; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — basic liveness checks
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 and logs 'scanner is live' when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_WATCHDOG_STALE=600 \
            LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is live"* ]]
}

@test "scanner-watchdog.sh: detects stale heartbeat and reports in dry-run" {
    # Write a heartbeat that is 700 seconds old.
    local old_time=$(( $(date +%s) - 700 ))
    printf '%s\n' "$old_time" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Also set the file mtime to match so stat-based age check is consistent.
    touch -t "$(date -r "$old_time" '+%Y%m%d%H%M.%S' 2>/dev/null || \
                date -d "@$old_time" '+%Y%m%d%H%M.%S' 2>/dev/null || \
                echo "202001010000.00")" \
        "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_WATCHDOG_STALE=600 \
            LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "scanner-watchdog.sh: exits 0 when heartbeat file is missing (treated as stale)" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_WATCHDOG_STALE=600 \
            LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}
