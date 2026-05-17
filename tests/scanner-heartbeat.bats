#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat and watchdog tests.
# Covers:
#   1. scanner.sh writes the heartbeat file on every tick (run_once).
#   2. scanner-watchdog.sh exits cleanly when the heartbeat is fresh.
#   3. scanner-watchdog.sh detects a stale heartbeat and kills the locked PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh functions only (stop before acquire_lock).
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
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log/dispatch so run_once doesn't attempt real gh calls.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/stage-age" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat written by run_once
# ---------------------------------------------------------------------------

@test "run_once writes heartbeat file to LOOP_LOG_DIR" {
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once heartbeat file contains a numeric epoch timestamp" {
    run_once
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "run_once updates heartbeat mtime on each call" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat")
    # Backdate the file so any new write produces a measurably different mtime.
    touch -t "$(date -v-1M +%Y%m%d%H%M.%S 2>/dev/null \
               || date -d '1 minute ago' +%Y%m%d%H%M.%S)" \
          "${LOOP_LOG_DIR}/scanner-heartbeat"
    run_once
    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once does NOT write heartbeat in dry-run mode" {
    DRY_RUN=true
    run_once
    [ ! -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with no message when heartbeat is fresh" {
    # Write a brand-new heartbeat.
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Low threshold so even a fresh file triggers "healthy" path.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_WATCHDOG_STALE_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "scanner-watchdog: exits 0 when heartbeat file is absent (first start)" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]] || [[ "$output" == *"not yet started"* ]]
}

@test "scanner-watchdog --dry-run: reports stale but does not kill any PID" {
    # Write a backdated heartbeat.
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null \
               || date -d '1 hour ago' +%Y%m%d%H%M.%S)" \
          "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_WATCHDOG_STALE_THRESHOLD=60 \
            LOOP_EXTRA_PATH="" \
            "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"STALE"* ]]
}
