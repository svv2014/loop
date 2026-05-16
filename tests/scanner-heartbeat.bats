#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify heartbeat file is written on every scanner tick.
#
# Uses the same source-extraction strategy as scanner.bats: awk strips the
# acquire_lock call and arg-parsing block so we can source scanner.sh functions
# directly without starting the daemon loop.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH=""

    local _src="$BATS_TMPDIR/scanner-src-hb.sh"
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
    LOG_FILE="$BATS_TMPDIR/scanner-hb-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log()           { :; }
    dispatch_direct() { :; }
    loop_list_slugs() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-hb-test.log" \
           "$BATS_TMPDIR/scanner-src-hb.sh" 2>/dev/null || true
}

@test "run_once: writes scanner-heartbeat file to LOOP_LOG_DIR" {
    run_once
    [ -f "${LOOP_LOG_DIR}/scanner-heartbeat" ]
}

@test "run_once: heartbeat file contains a recent epoch timestamp" {
    run_once
    local ts
    ts=$(cat "${LOOP_LOG_DIR}/scanner-heartbeat")
    local now
    now=$(date +%s)
    # Timestamp must be numeric and within 10 seconds of now.
    [[ "$ts" =~ ^[0-9]+$ ]]
    local diff=$(( now - ts ))
    [ "$diff" -ge 0 ]
    [ "$diff" -lt 10 ]
}

@test "run_once: heartbeat file mtime is updated on repeated calls" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)

    # Brief sleep to ensure mtime can change (1-second resolution on most FS).
    sleep 1
    run_once

    local mtime2
    mtime2=$(stat -f%m "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "scanner-watchdog.sh: exits 0 with healthy heartbeat" {
    # Write a fresh heartbeat.
    printf '%s\n' "$(date +%s)" > "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_THRESHOLD=600 \
        "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner healthy"* ]]
}

@test "scanner-watchdog.sh: reports stale when heartbeat is old" {
    # Write a heartbeat with a timestamp 700 seconds in the past.
    printf '%s\n' "$(( $(date +%s) - 700 ))" > "${LOOP_LOG_DIR}/scanner-heartbeat"
    # Back-date the file mtime to match.
    touch -t "$(date -v-700S '+%Y%m%d%H%M.%S' 2>/dev/null \
                || date -d '700 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
                || date '+%Y%m%d%H%M.%S')" \
        "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        LOOP_WATCHDOG_STALE_THRESHOLD=600 \
        "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"appears wedged"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog.sh: exits 0 when no heartbeat file exists" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not yet started"* ]]
}
