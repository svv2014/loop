#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#   1. _scanner_write_heartbeat writes an epoch timestamp to scanner-heartbeat.
#   2. Calling it again updates the file (mtime advances).
#   3. DRY_RUN=true suppresses the write.
#   4. scanner-watchdog.sh exits 0 and logs OK when heartbeat is fresh.
#   5. scanner-watchdog.sh exits 0 and logs STALE when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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

    # Silence log() to avoid cluttering bats output.
    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file with epoch timestamp" {
    DRY_RUN=false
    _scanner_write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Timestamp should be a positive integer
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "_scanner_write_heartbeat: updates file on second call" {
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

@test "_scanner_write_heartbeat: skipped when DRY_RUN=true" {
    DRY_RUN=true
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    _scanner_write_heartbeat
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 and prints OK when heartbeat is fresh" {
    # Write a fresh heartbeat.
    date +%s > "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK heartbeat"* ]]
}

@test "scanner-watchdog: logs STALE and dry-run message when heartbeat is old" {
    # Write a heartbeat with a timestamp far in the past (2 hours ago).
    local past=$(( $(date +%s) - 7200 ))
    echo "$past" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Backdate the file mtime so stat sees it as old.
    touch -t "$(date -r "$past" '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d "@$past" '+%Y%m%d%H%M.%S' 2>/dev/null \
        || echo '200001010000.00')" \
        "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog: exits 0 with message when heartbeat file absent" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]]
}
