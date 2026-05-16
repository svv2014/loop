#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner heartbeat and watchdog behaviour.

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
    _write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_write_heartbeat: heartbeat file contains a timestamp" {
    _write_heartbeat
    local content
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [[ "$content" == *"20"* ]]
}

@test "_write_heartbeat: heartbeat file contains scanner PID" {
    _write_heartbeat
    local content
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [[ "$content" == *"pid=$$"* ]]
}

@test "_write_heartbeat: updates mtime on each call" {
    # stat -f%m is macOS-specific; skip on platforms where it is unavailable.
    _write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null) || skip "stat -f%m unavailable"
    sleep 1
    _write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_write_heartbeat: no-op in dry-run mode" {
    DRY_RUN=true
    _write_heartbeat
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# run_once writes heartbeat
# ---------------------------------------------------------------------------

@test "run_once: writes heartbeat file on every tick" {
    # Stub out all project scanning so run_once completes quickly.
    loop_list_slugs()    { return 0; }
    _sweep_stale_locks() { return 0; }
    jobs_init_schema()   { return 0; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — basic behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with INFO when heartbeat file is absent" {
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "scanner-watchdog: reports OK when heartbeat is fresh" {
    touch "${LOOP_LOG_DIR}/scanner-heartbeat"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "scanner-watchdog --dry-run: reports stale but does not kill when heartbeat is old" {
    # Create a heartbeat file with an old mtime (touch -t sets mtime).
    touch "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Back-date it 60 seconds. Use a very short interval (5s) + mult=2 so
    # threshold is 10s — well below 60s regardless of operator's loop.env.
    local old_time
    old_time=$(date -v -60S '+%Y%m%d%H%M.%S' 2>/dev/null \
               || date -d '60 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
               || { skip "date -v/-d unavailable on this platform"; return; })
    touch -t "$old_time" "${LOOP_LOG_DIR}/scanner-heartbeat"

    # Write a dummy lock file pointing at a non-existent PID.
    echo "999999" > /tmp/loop-scanner.lock

    # Force a known-short interval so the stale threshold is 10s (5*2),
    # well below the 60s back-dated mtime — independent of operator loop.env.
    run env LOOP_SCANNER_INTERVAL=5 LOOP_SCANNER_STALE_MULT=2 \
        "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    rm -f /tmp/loop-scanner.lock

    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
