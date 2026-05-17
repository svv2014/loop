#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner heartbeat and watchdog behaviour.
#
# Heartbeat: run_once() must touch ${LOOP_LOG_DIR}/scanner-heartbeat on each tick.
# Watchdog: scanner-watchdog.sh must report healthy/stale based on heartbeat mtime.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose a no-op mock gh so env.sh sources cleanly.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"
    export LOOP_EXTRA_PATH=""

    # Extract run_once + its helpers from scanner.sh (stop before acquire_lock).
    local _src="$BATS_TMPDIR/scanner-hb-src.sh"
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

    # Override dirs and helpers so run_once does not do real work.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"
    log()            { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema()   { :; }
    loop_list_slugs()    { printf ''; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat on first tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb" ]
    run_once
    [ -f "$hb" ]
}

@test "run_once: updates scanner-heartbeat mtime on each tick" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    touch -t 202001010000 "$hb"
    local before
    before=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    sleep 1
    run_once
    local after
    after=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)
    [ "$after" -gt "$before" ]
}

# ---------------------------------------------------------------------------
# Watchdog: healthy case
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 and reports healthy when heartbeat is fresh" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    touch "$hb"   # mtime = now
    export LOOP_SCANNER_INTERVAL=300
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner healthy"* ]]
}

# ---------------------------------------------------------------------------
# Watchdog: stale case (dry-run so no kill/launchctl side-effects)
# ---------------------------------------------------------------------------

@test "scanner-watchdog: reports stale when heartbeat is old" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    touch -t 202001010000 "$hb"   # epoch-like ancient mtime
    export LOOP_SCANNER_INTERVAL=300
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog: exits 0 and skips when heartbeat absent" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    rm -f "$hb"
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat absent"* ]]
}
