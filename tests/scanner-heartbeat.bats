#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file written on every scanner tick.
#
# Verifies that run_once() writes ${LOOP_LOG_DIR}/scanner-heartbeat and that
# the watchdog script correctly identifies stale vs. alive scanners.

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
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"
    touch "$LOG_FILE"

    DRY_RUN=false
    ONCE=true
}

teardown() {
    rm -f "$LOG_FILE" "$HEARTBEAT_FILE"
}

@test "scanner.sh defines HEARTBEAT_FILE variable" {
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
}

@test "_scanner_write_heartbeat creates heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    _scanner_write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_write_heartbeat writes current epoch to heartbeat file" {
    _scanner_write_heartbeat
    local content
    content=$(cat "$HEARTBEAT_FILE")
    local now
    now=$(date +%s)
    # Epoch in file should be within 5 seconds of now.
    [ $(( now - content )) -le 5 ]
}

@test "_scanner_write_heartbeat updates mtime on repeated calls" {
    _scanner_write_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    _scanner_write_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "watchdog.sh exits 0 when no heartbeat file exists" {
    rm -f "$HEARTBEAT_FILE"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" run "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file yet"* ]]
}

@test "watchdog.sh exits 0 when heartbeat is fresh" {
    _scanner_write_heartbeat
    LOOP_LOG_DIR="$LOOP_LOG_DIR" run "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner alive"* ]]
}

@test "watchdog.sh detects stale heartbeat in DRY_RUN mode" {
    # Create a heartbeat file with an old mtime (25 minutes ago).
    _scanner_write_heartbeat
    local old_time=$(( $(date +%s) - 1500 ))
    touch -t "$(date -r "$old_time" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$old_time" '+%Y%m%d%H%M.%S' 2>/dev/null || echo "197001010000.00")" "$HEARTBEAT_FILE" 2>/dev/null || true
    # Use a short poll interval so the threshold is easy to exceed.
    LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=300 DRY_RUN=true \
        run "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
