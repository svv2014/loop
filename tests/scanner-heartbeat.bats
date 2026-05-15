#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 liveness heartbeat.
#
# Verifies that run_once() writes a fresh heartbeat file on every tick, and
# that scanner-watchdog.sh correctly detects fresh vs. stale heartbeats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    touch "$LOG_FILE"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence noisy output; short-circuit scan_project so run_once exits fast.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" "$BATS_TMPDIR/scanner-test.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat write
# ---------------------------------------------------------------------------

@test "run_once: writes scanner-heartbeat to LOOP_LOG_DIR" {
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat contains a unix timestamp (all digits)" {
    run_once
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [[ "$content" =~ ^[0-9]+$ ]]
}

@test "run_once: heartbeat mtime is recent (within 5s)" {
    run_once
    now=$(date +%s)
    mtime=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)
    age=$(( now - mtime ))
    [ "$age" -le 5 ]
}

@test "run_once: DRY_RUN skips heartbeat write" {
    DRY_RUN=true
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: overwrites stale heartbeat on each tick" {
    # Write an old timestamp
    printf '1000000000\n' > "${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    content=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    now=$(date +%s)
    [ "$content" -gt 1000000000 ]
    [ "$content" -le "$now" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh logic
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 (no heartbeat file = first start)" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
}

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat ok"* ]]
}

@test "scanner-watchdog: detects stale heartbeat and logs WARN" {
    # Touch the heartbeat file then backdate it well past the threshold (2x POLL_INTERVAL).
    printf '1000000000\n' > "${LOOP_LOG_DIR}/scanner-heartbeat"
    touch -t 200001010000 "${LOOP_LOG_DIR}/scanner-heartbeat"
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"stale"* ]]
}
