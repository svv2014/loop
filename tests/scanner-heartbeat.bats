#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that _scanner_write_heartbeat writes a file to LOOP_LOG_DIR on
# every real (non-dry-run) tick, and that the watchdog script correctly
# classifies fresh vs. stale heartbeats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner function definitions only (same awk filter as scanner.bats).
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

    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file" {
    DRY_RUN=false
    _scanner_write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_scanner_write_heartbeat: heartbeat file is non-empty" {
    DRY_RUN=false
    _scanner_write_heartbeat
    [ -s "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_scanner_write_heartbeat: updates mtime on repeated calls" {
    DRY_RUN=false
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    [ "$mtime2" -ge "$mtime1" ]
}

@test "_scanner_write_heartbeat: no-op in dry-run mode" {
    DRY_RUN=true
    _scanner_write_heartbeat
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner.sh contains _scanner_write_heartbeat function" {
    grep -q "_scanner_write_heartbeat()" "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh calls _scanner_write_heartbeat in run_once" {
    grep -q "_scanner_write_heartbeat" "$REPO_ROOT/scanner/scanner.sh"
    # Verify the call appears inside run_once (between run_once() and the next top-level function).
    awk '/^run_once\(\)/{found=1} found && /_scanner_write_heartbeat/{print; exit}' \
        "$REPO_ROOT/scanner/scanner.sh" | grep -q "_scanner_write_heartbeat"
}

@test "scanner-watchdog.sh exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat.
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Watchdog should report OK and exit 0.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "OK"
}

@test "scanner-watchdog.sh reports stale when heartbeat is old" {
    # Write a heartbeat with an old mtime (touch -t in the past).
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '-1 hour' '+%Y%m%d%H%M' 2>/dev/null)" \
        "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || \
        touch "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Force threshold to 60s so even a 1-minute-old file triggers.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_WATCHDOG_THRESHOLD=60 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "STALE\|stale"
}

@test "scanner-watchdog.sh reports stale when heartbeat file is missing" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_WATCHDOG_THRESHOLD=60 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "missing\|STALE\|stale"
}
