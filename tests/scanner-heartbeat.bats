#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat (issue #413).
#
# Verifies that run_once() touches $HEARTBEAT_FILE on every tick so the
# external watchdog (restart-scanner-if-stale.sh) can detect a silently
# wedged scanner.

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
    LOG_FILE="$BATS_TMPDIR/logs/scanner-test.log"
    touch "$LOG_FILE"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    LOOP_JOBS_ENQUEUE=0

    # Override functions that would require real infrastructure
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs() { printf ''; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file written on every tick
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file on first tick" {
    HEARTBEAT_FILE="$BATS_TMPDIR/logs/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run_once

    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file mtime advances between ticks" {
    # stat -f%m is macOS-specific; skip if unavailable.
    if ! stat -f%m "$LOG_FILE" 2>/dev/null; then
        skip "stat -f%m not available on this platform"
    fi

    HEARTBEAT_FILE="$BATS_TMPDIR/logs/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run_once

    [ -f "$HEARTBEAT_FILE" ]
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE")

    sleep 1

    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE")

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: heartbeat path uses LOOP_LOG_DIR" {
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$HEARTBEAT_FILE"

    run_once

    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh — staleness detection
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale: exits 0 when heartbeat is fresh" {
    local hb="$BATS_TMPDIR/logs/scanner-heartbeat"
    touch "$hb"

    LOOP_SCANNER_STALE_THRESHOLD=900 \
    LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: heartbeat age="* ]]
}

@test "restart-scanner-if-stale: exits 0 when heartbeat file missing (first start)" {
    rm -f "$BATS_TMPDIR/logs/scanner-heartbeat"

    LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat file missing"* ]]
}

@test "restart-scanner-if-stale: detects stale heartbeat and logs restart in dry-run" {
    local hb="$BATS_TMPDIR/logs/scanner-heartbeat"
    touch -t 197001010000 "$hb"   # epoch 0 — definitely stale

    LOOP_SCANNER_STALE_THRESHOLD=60 \
    LOOP_LOG_DIR="$BATS_TMPDIR/logs" \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
