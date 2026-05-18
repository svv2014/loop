#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file and watchdog restart logic.
#
# Covers:
#   - _scanner_write_heartbeat creates/updates the heartbeat file every tick
#   - scanner-watchdog.sh reports OK when heartbeat is fresh
#   - scanner-watchdog.sh reports STALE when heartbeat is old (dry-run)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same pattern as scanner.bats).
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
    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file" {
    _scanner_write_heartbeat
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "_scanner_write_heartbeat: heartbeat contains current epoch timestamp" {
    local before after ts
    before=$(date +%s)
    _scanner_write_heartbeat
    after=$(date +%s)
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [ "$ts" -ge "$before" ]
    [ "$ts" -le "$after" ]
}

@test "_scanner_write_heartbeat: repeated calls update mtime" {
    _scanner_write_heartbeat
    sleep 1
    _scanner_write_heartbeat
    local age
    age=$(( $(date +%s) - $(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || echo 0) ))
    [ "$age" -le 2 ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh (dry-run mode — no kills)
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 with OK when heartbeat is fresh" {
    # Write a fresh heartbeat; regardless of LOOP_SCANNER_INTERVAL the file
    # was just written so mtime age is near 0.
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=60 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat OK"* ]]
}

@test "scanner-watchdog.sh: reports STALE when heartbeat mtime is old" {
    # Use a short poll interval (60s) so the stale threshold is 120s.
    # Backdate the heartbeat by 300s (well past the 120s threshold).
    printf '%s\n' "old" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    python3 -c "
import os, time
p = '${LOOP_LOG_DIR}/scanner-heartbeat'
old = time.time() - 300
os.utime(p, (old, old))
"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=60 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "scanner-watchdog.sh: exits 0 gracefully when no heartbeat file exists" {
    # No heartbeat file — scanner not yet started.
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=60 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file"* ]]
}
