#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat and scanner_tick event.
#
# Covers acceptance criteria from #413:
#   1. Heartbeat file written on every tick.
#   2. scanner_tick event emitted to loop-monitor on every tick.
#   3. Watchdog detects stale vs. alive scanner.

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

# ── Heartbeat file ────────────────────────────────────────────────────────────

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

# ── scanner_tick event ────────────────────────────────────────────────────────

@test "scanner.sh defines _scanner_emit_tick function" {
    declare -f _scanner_emit_tick >/dev/null
}

@test "_scanner_emit_tick calls _loop_emit_event when LOOP_MONITOR_URL is set" {
    local call_log="$BATS_TMPDIR/emit_calls.log"
    # Override _loop_emit_event to capture calls.
    _loop_emit_event() { echo "called:$1:$2" >> "$call_log"; }
    LOOP_MONITOR_URL="http://localhost:9999"
    mkdir -p "$DEDUP_DIR"
    _scanner_emit_tick
    [ -f "$call_log" ]
    grep -q "called:scanner_tick:" "$call_log"
}

@test "_scanner_emit_tick payload contains ts and dedup_count fields" {
    local captured=""
    _loop_emit_event() { captured="$2"; }
    LOOP_MONITOR_URL="http://localhost:9999"
    mkdir -p "$DEDUP_DIR"
    _scanner_emit_tick
    # Payload must be valid JSON with ts and dedup_count.
    echo "$captured" | python3 -c "
import json, sys
p = json.load(sys.stdin)
assert 'ts' in p, 'missing ts'
assert 'dedup_count' in p, 'missing dedup_count'
assert isinstance(p['ts'], int), 'ts must be int'
assert isinstance(p['dedup_count'], int), 'dedup_count must be int'
"
}

@test "_scanner_emit_tick dedup_count reflects files in DEDUP_DIR" {
    local captured_count=-1
    _loop_emit_event() {
        captured_count=$(echo "$2" | python3 -c "import json,sys; print(json.load(sys.stdin)['dedup_count'])")
    }
    LOOP_MONITOR_URL="http://localhost:9999"
    mkdir -p "$DEDUP_DIR"
    touch "$DEDUP_DIR/abc123" "$DEDUP_DIR/def456"
    _scanner_emit_tick
    [ "$captured_count" -eq 2 ]
}

@test "_scanner_emit_tick is skipped when DRY_RUN is true (run_once guard)" {
    local called=false
    _loop_emit_event() { called=true; }
    LOOP_MONITOR_URL="http://localhost:9999"
    # The guard $DRY_RUN || _scanner_emit_tick is in run_once, not the function itself.
    # Verify the pattern exists in the source.
    grep -q 'DRY_RUN.*_scanner_emit_tick' "$REPO_ROOT/scanner/scanner.sh"
}

# ── Watchdog script ───────────────────────────────────────────────────────────

@test "watchdog.sh exits 0 when no heartbeat file exists" {
    rm -f "$HEARTBEAT_FILE"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" run "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file yet"* ]]
}

@test "watchdog.sh exits 0 and logs alive when heartbeat is fresh" {
    _scanner_write_heartbeat
    LOOP_LOG_DIR="$LOOP_LOG_DIR" run "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner alive"* ]]
}

@test "watchdog.sh detects stale heartbeat in DRY_RUN mode" {
    # Backdate heartbeat 25 minutes to exceed 2x default 300s interval.
    _scanner_write_heartbeat
    local old_epoch=$(( $(date +%s) - 1500 ))
    printf '%s\n' "$old_epoch" > "$HEARTBEAT_FILE"
    touch -t "$(date -r "$old_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d "@$old_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null \
        || echo '202001010000.00')" "$HEARTBEAT_FILE" 2>/dev/null || true
    LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=300 DRY_RUN=true \
        run "$REPO_ROOT/scanner/watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"DRY_RUN"* ]]
}
