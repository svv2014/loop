#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — scanner liveness heartbeat (#413).
#
# Verifies that scanner.sh touches ${LOOP_LOG_DIR}/scanner-heartbeat on every
# run_once() call (non-dry-run), and that scanner-watchdog.sh correctly detects
# a stale heartbeat and reports it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh does not prepend /opt/homebrew/bin
    export LOOP_EXTRA_PATH=""

    # Mock PATH so gh, launchctl, etc. don't run real binaries.
    mkdir -p "$BATS_TMPDIR/bin"
    # Stub gh — returns empty arrays for all list calls.
    cat > "$BATS_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "[]"
SH
    chmod +x "$BATS_TMPDIR/bin/gh"
    # Stub launchctl — noop so watchdog's kickstart call doesn't fail the test.
    cat > "$BATS_TMPDIR/bin/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$BATS_TMPDIR/bin/launchctl"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Source scanner.sh function definitions only (same strategy as scanner.bats).
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
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() and no-op dispatch_direct / scan_project so run_once completes fast.
    log() { :; }
    dispatch_direct() { :; }
    scan_project() { :; }
    loop_list_slugs() { printf ''; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat file in scanner.sh
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created on first tick" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "run_once: heartbeat file mtime is updated on every tick" {
    touch -t "200001010000" "$LOOP_LOG_DIR/scanner-heartbeat"
    local before
    before=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
             || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    run_once
    local after
    after=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
            || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)
    [ "$after" -gt "$before" ]
}

@test "run_once --dry-run: heartbeat file is NOT written" {
    DRY_RUN=true
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh logic
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat is fresh" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    # LOOP_SCANNER_STALE_THRESHOLD=600 — fresh file is well within threshold.
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner healthy"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat is old" {
    # Make the heartbeat look old (year 2000).
    touch -t "200001010000" "$LOOP_LOG_DIR/scanner-heartbeat"
    # Use a tiny threshold so even a freshly-touched file would qualify — but
    # here we set threshold=1 and an ancient mtime so it definitely fires.
    LOOP_SCANNER_STALE_THRESHOLD=1 \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would kill"* ]] || [[ "$output" == *"stale"* ]]
}

@test "scanner-watchdog: exits 0 when heartbeat file is absent (treats as stale)" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_SCANNER_STALE_THRESHOLD=1 \
    run bash "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]] || [[ "$output" == *"would kill"* ]]
}
