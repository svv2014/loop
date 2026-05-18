#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat + watchdog (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""
    export LOOP_SCANNER_INTERVAL=300
}

teardown() {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
}

# ── scanner.sh: heartbeat written on every tick ───────────────────────────────

@test "scanner run_once writes heartbeat file to LOOP_LOG_DIR" {
    # Source scanner definitions (same extraction pattern as scanner.bats).
    local src="$BATS_TMPDIR/scanner-src.sh"
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
    } > "$src"
    # shellcheck disable=SC1090
    source "$src"

    # Stub out everything that touches GitHub / project config so run_once
    # only needs to complete the heartbeat write and tick-start log.
    loop_list_slugs()          { printf ''; }
    _sweep_stale_locks()       { :; }
    jobs_init_schema()         { :; }
    LOOP_JOBS_ENQUEUE=0

    run_once

    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
    local ts
    ts=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    # Content must be a unix epoch (numeric, non-empty).
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "scanner run_once updates heartbeat timestamp on each call" {
    local src="$BATS_TMPDIR/scanner-src2.sh"
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
    } > "$src"
    # shellcheck disable=SC1090
    source "$src"

    loop_list_slugs()    { printf ''; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    LOOP_JOBS_ENQUEUE=0

    run_once
    local t1
    t1=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")

    sleep 1

    run_once
    local t2
    t2=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")

    # Second tick must have a timestamp >= first tick.
    [ "$t2" -ge "$t1" ]
}

@test "scanner run_once does NOT write heartbeat in dry-run mode" {
    local src="$BATS_TMPDIR/scanner-src3.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        awk '
            /^SCRIPT_DIR=/           { next }
            /^LOOP_ROOT=/            { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=true"; print "ONCE=true"; next }
            skip && /^done$/         { skip=0; next }
            skip                     { next }
            /^acquire_lock$/         { exit }
            { print }
        ' "$REPO_ROOT/scanner/scanner.sh"
    } > "$src"
    # shellcheck disable=SC1090
    source "$src"

    loop_list_slugs()    { printf ''; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    LOOP_JOBS_ENQUEUE=0

    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run_once

    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ── scanner-watchdog.sh ───────────────────────────────────────────────────────

@test "scanner-watchdog exits ok when heartbeat is fresh" {
    # Write a heartbeat timestamped now.
    date +%s > "$LOOP_LOG_DIR/scanner-heartbeat"

    export LOOP_SCANNER_STALE_THRESHOLD=600
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok (heartbeat fresh)"* ]]
}

@test "scanner-watchdog exits ok when no heartbeat file exists" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    export LOOP_SCANNER_STALE_THRESHOLD=600
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not yet started"* ]]
}

@test "scanner-watchdog reports stale heartbeat in dry-run" {
    # Write a heartbeat from 700s ago by back-dating the file mtime.
    date +%s > "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t "$(date -v-700S '+%Y%m%d%H%M.%S' 2>/dev/null \
               || date --date='700 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
               || date '+%Y%m%d%H%M.%S')" \
          "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || \
    python3 -c "
import os, time
path='$LOOP_LOG_DIR/scanner-heartbeat'
t = time.time() - 700
os.utime(path, (t, t))
"

    export LOOP_SCANNER_STALE_THRESHOLD=600
    run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
