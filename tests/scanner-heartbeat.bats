#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is updated on every scanner tick,
# and scanner-watchdog.sh stale-detection logic.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    LOOP_JOBS_ENQUEUE=0

    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs() { :; }
    jobs_init_schema() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_update_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_update_heartbeat: creates heartbeat file in LOOP_LOG_DIR" {
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
    _scanner_update_heartbeat
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "_scanner_update_heartbeat: writes a timestamp" {
    _scanner_update_heartbeat
    local content
    content=$(cat "$LOOP_LOG_DIR/scanner-heartbeat")
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "_scanner_update_heartbeat: updates mtime on successive calls" {
    _scanner_update_heartbeat
    local mtime1
    mtime1=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat")
    sleep 1
    _scanner_update_heartbeat
    local mtime2
    mtime2=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat")
    [ "$mtime2" -gt "$mtime1" ]
}

@test "run_once: heartbeat file written when DRY_RUN=false" {
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
    DRY_RUN=false run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "run_once: heartbeat file NOT written when DRY_RUN=true" {
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
    DRY_RUN=true run_once
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with 'ok' when heartbeat is fresh" {
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=300 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ok:" ]]
}

@test "scanner-watchdog: exits 0 when heartbeat file absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=300 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "absent" ]]
}

@test "scanner-watchdog --dry-run: reports stale without killing when heartbeat is old" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    printf 'old\n' > "$hb"
    # Backdate mtime by 1 hour
    touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null \
        || date -d '-1 hour' '+%Y%m%d%H%M' 2>/dev/null \
        || date '+%Y%m%d%H%M')" "$hb" 2>/dev/null \
        || touch -A -010000 "$hb" 2>/dev/null || true
    local age
    age=$(( $(date +%s) - $(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb") ))
    if [ "$age" -lt 600 ]; then
        skip "could not backdate mtime far enough (age=${age}s)"
    fi

    LOOP_LOG_DIR="$LOOP_LOG_DIR" LOOP_SCANNER_INTERVAL=300 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ "WARN" ]]
    [[ "$output" =~ "dry-run" ]]
}
