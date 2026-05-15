#!/usr/bin/env bats
# tests/scanner-watchdog.bats — scanner heartbeat and watchdog tests.
#
# 1. Verifies scanner.sh writes the heartbeat file on every run_once() tick.
# 2. Verifies scanner-watchdog.sh exits OK when heartbeat is fresh.
# 3. Verifies scanner-watchdog.sh --dry-run reports STALE without killing anything
#    when the heartbeat is older than 2 * POLL_INTERVAL.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Pre-set LOOP_EXTRA_PATH so env.sh does not prepend /opt/homebrew and
    # shadow mock binaries we may place in BATS_TMPDIR/bin.
    export LOOP_EXTRA_PATH=""

    # Minimal scanner source (same awk extraction as tests/scanner.bats).
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

    # Silence side-effecting functions that scanner.sh calls during run_once.
    log()              { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs()  { :; }
    jobs_init_schema() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat — scanner writes file on every tick
# ---------------------------------------------------------------------------

@test "scanner.sh: _scanner_write_heartbeat function exists" {
    declare -f _scanner_write_heartbeat >/dev/null
}

@test "scanner.sh: run_once writes heartbeat file to LOOP_LOG_DIR" {
    run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "scanner.sh: run_once updates heartbeat mtime on each call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    # Force a detectable mtime difference.
    sleep 1.1
    run_once

    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    [ "$mtime2" -gt "$mtime1" ]
}

# ---------------------------------------------------------------------------
# Watchdog — reports OK when heartbeat is fresh
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 when heartbeat is fresh" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: scanner is alive"* ]]
}

# ---------------------------------------------------------------------------
# Watchdog — dry-run reports stale heartbeat without killing anything
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: --dry-run reports STALE for old heartbeat" {
    # Create a heartbeat file with an artificially old mtime (>10 min ago).
    touch -t "$(date -v-20M '+%Y%m%d%H%M' 2>/dev/null \
               || date -d '-20 minutes' '+%Y%m%d%H%M' 2>/dev/null)" \
        "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || touch "$LOOP_LOG_DIR/scanner-heartbeat"

    # Use a very short threshold so even a just-created file looks stale.
    LOOP_SCANNER_INTERVAL=1 run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog.sh: exits 0 when heartbeat file does not exist yet" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}
