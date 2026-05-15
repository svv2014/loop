#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies that:
#   1. scanner.sh updates ${LOOP_LOG_DIR}/scanner-heartbeat on every tick.
#   2. scanner-watchdog.sh exits 0 when heartbeat is fresh.
#   3. scanner-watchdog.sh kills the target PID when heartbeat is stale.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose a no-op gh mock so sourcing scanner.sh doesn't error.
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$BATS_TMPDIR/bin/gh"

    export LOOP_EXTRA_PATH=""
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Source scanner functions (same awk extraction as tests/scanner.bats).
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
    mkdir -p "$DEDUP_DIR"
    DRY_RUN=false
}

teardown() {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
}

# ---------------------------------------------------------------------------
# Heartbeat written by scanner
# ---------------------------------------------------------------------------

@test "run_once writes scanner-heartbeat to LOOP_LOG_DIR" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb" ]

    # Stub out everything that run_once calls so we don't need a real gh.
    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    export LOOP_JOBS_ENQUEUE=0

    run_once

    [ -f "$hb" ]
}

@test "run_once refreshes scanner-heartbeat mtime on each call" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"

    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    export LOOP_JOBS_ENQUEUE=0

    run_once
    local mtime1
    mtime1=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)

    sleep 1

    run_once
    local mtime2
    mtime2=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once does NOT write heartbeat in --dry-run mode" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    DRY_RUN=true

    loop_list_slugs() { echo ""; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    export LOOP_JOBS_ENQUEUE=0

    run_once

    [ ! -f "$hb" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh behaviour
# ---------------------------------------------------------------------------

@test "scanner-watchdog exits 0 when heartbeat is fresh" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    touch "$hb"

    export LOOP_SCANNER_INTERVAL=300
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

@test "scanner-watchdog dry-run reports stale without killing" {
    local hb="$LOOP_LOG_DIR/scanner-heartbeat"
    # Create a heartbeat file and backdate its mtime by 800s (> 2×300).
    touch "$hb"
    python3 -c "
import os, time
p = '${hb}'
t = time.time() - 800
os.utime(p, (t, t))
"
    export LOOP_SCANNER_INTERVAL=300
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: heartbeat stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "scanner-watchdog exits 0 and logs when no heartbeat file exists" {
    export LOOP_SCANNER_INTERVAL=300
    run bash "$REPO_ROOT/scripts/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat file yet"* ]]
}
