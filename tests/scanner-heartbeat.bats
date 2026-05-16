#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 scanner liveness heartbeat.
#
# Verifies:
#  1. scanner.sh writes the heartbeat file on every run_once() tick.
#  2. restart-scanner-if-stale.sh exits 0 (no restart) when heartbeat is fresh.
#  3. restart-scanner-if-stale.sh detects a stale heartbeat and kills the PID.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh does not prepend /opt/homebrew/bin
    export LOOP_EXTRA_PATH=""

    # Source scanner.sh function definitions only (same technique as scanner.bats).
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

    # Override paths set after sourcing.
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false

    # Stub out functions that require a real environment.
    log() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-test.log" "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file written on every tick
# ---------------------------------------------------------------------------

@test "run_once: writes heartbeat file on each tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: heartbeat file contains a unix timestamp" {
    run_once
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    # Must be a non-empty integer greater than a plausible epoch floor (2020-01-01).
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -gt 1577836800 ]
}

@test "run_once: heartbeat mtime is updated on second tick" {
    run_once
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    run_once
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$mtime2" -ge "$mtime1" ]
}

@test "run_once: does NOT write heartbeat file in dry-run mode" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# Watchdog script behaviour
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale: exits 0 when heartbeat is fresh" {
    # Write a fresh heartbeat.
    date +%s > "$HEARTBEAT_FILE"

    # Run watchdog with a very generous threshold so fresh file is always fine.
    LOOP_HEARTBEAT_STALE_SECONDS=9999 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
}

@test "restart-scanner-if-stale: detects missing heartbeat as stale and logs warning" {
    rm -f "$HEARTBEAT_FILE"

    # Stub launchctl so we don't touch any real system state.
    local stub_bin="$BATS_TMPDIR/stub-bin"
    mkdir -p "$stub_bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/launchctl"
    chmod +x "$stub_bin/launchctl"

    # Use a lock file with a dead PID so the kill path hits the stale-lock
    # branch (remove file) instead of actually sending a signal.
    echo "999999999" > /tmp/loop-scanner.lock

    PATH="$stub_bin:$PATH" \
    LOOP_HEARTBEAT_STALE_SECONDS=1 \
    LOOP_LOG_DIR="$LOOP_LOG_DIR" \
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"

    # Watchdog must exit 0.
    [ "$status" -eq 0 ]

    # Log must contain the stale-scanner warning.
    grep -q "wedged" "$LOOP_LOG_DIR/loop-scanner-watchdog.log"

    rm -f /tmp/loop-scanner.lock
}
