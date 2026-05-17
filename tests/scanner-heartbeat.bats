#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file written on every tick (#413).
#
# Verifies that run_once() touches ${LOOP_LOG_DIR}/scanner-heartbeat and that
# the watchdog script correctly distinguishes a fresh heartbeat from a stale one.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Build a minimal version of scanner.sh with functions only (same pattern as
    # scanner.bats — write to temp file because bash 3.2 doesn't propagate defs
    # from source <(...)).
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() and stub out all I/O-heavy helpers.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/stage-age" "$BATS_TMPDIR/scanner-src.sh" \
           "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

@test "run_once: writes heartbeat file to LOOP_LOG_DIR" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "run_once: updates heartbeat mtime on every call" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: dry-run does NOT write heartbeat file" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    DRY_RUN=true
    run_once
    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh unit-level checks
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 when heartbeat is fresh" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    touch "$hb"

    # Run watchdog with a very short stale threshold — heartbeat was just touched
    # so age should be 0s, well under any threshold.
    LOOP_SCANNER_STALE_SECONDS=900 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "scanner-watchdog.sh: exits 0 when heartbeat file is absent" {
    # No heartbeat file — watchdog should warn but not crash.
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing"* ]]
}

@test "scanner-watchdog.sh: detects stale heartbeat and logs WARN" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    touch -t 200001010000 "$hb"   # set mtime to year 2000 — definitely stale

    LOOP_SCANNER_STALE_SECONDS=900 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}
