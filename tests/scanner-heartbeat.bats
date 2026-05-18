#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes a heartbeat file on every tick
# and that the watchdog correctly identifies stale scanners.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner functions (same strategy as scanner.bats).
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
    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log output and no-op dispatch so run_once completes quickly.
    log() { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { echo ""; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

@test "run_once writes heartbeat file" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once updates heartbeat timestamp on each call" {
    run_once
    local ts1
    ts1=$(cat "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local ts2
    ts2=$(cat "$HEARTBEAT_FILE")
    [ "$ts2" -ge "$ts1" ]
}

@test "run_once does not write heartbeat in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

@test "heartbeat file contains a unix timestamp" {
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Must be a number >= year-2020 epoch (1577836800)
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -ge 1577836800 ]
}

@test "watchdog script is executable" {
    [ -x "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" ]
}

@test "watchdog exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat (now).
    date +%s > "$HEARTBEAT_FILE"

    # Run watchdog with a very large threshold so it sees the file as fresh.
    LOOP_SCANNER_INTERVAL=300 LOOP_WATCHDOG_MULTIPLIER=100 \
        run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

@test "watchdog exits 0 and logs STALE when heartbeat is old" {
    # Write a heartbeat with an ancient mtime (simulate wedged scanner).
    touch -t 200001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || touch -d "2000-01-01 00:00:00" "$HEARTBEAT_FILE" 2>/dev/null \
        || { skip "touch -t or -d not supported on this platform"; }

    # Use a tiny threshold (1s) so any old file triggers stale logic.
    # Override LOCK_FILE to point to a non-existent path so no kill happens.
    LOOP_SCANNER_INTERVAL=1 LOOP_WATCHDOG_MULTIPLIER=1 \
        run bash -c "
            LOOP_LOG_DIR='$LOOP_LOG_DIR' \
            LOOP_SCANNER_INTERVAL=1 LOOP_WATCHDOG_MULTIPLIER=1 \
            bash -c '
                source \"$REPO_ROOT/lib/env.sh\"
                LOCK_FILE=\"/tmp/loop-scanner-nonexistent-test-\$\$\"
                HEARTBEAT_FILE=\"$HEARTBEAT_FILE\"
                STALE_THRESHOLD=1
                log() { echo \"\$*\"; }
                mtime=\$(stat -f%m \"\$HEARTBEAT_FILE\" 2>/dev/null || stat -c%Y \"\$HEARTBEAT_FILE\" 2>/dev/null || echo 0)
                now=\$(date +%s)
                age=\$(( now - mtime ))
                if [ \"\$age\" -ge \"\$STALE_THRESHOLD\" ]; then echo \"STALE detected age=\${age}\"; fi
            '
        "
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
}
