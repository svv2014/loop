#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verifies heartbeat file is updated on every tick.
#
# Sourcing strategy mirrors tests/scanner.bats: awk strips the acquire_lock call
# and the argument-parsing for..done block so we can source function definitions
# into the test scope without starting the daemon loop.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_EXTRA_PATH="$BATS_TMPDIR/bin"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Minimal mock gh so env.sh and config.sh don't fail.
    cat > "$BATS_TMPDIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$BATS_TMPDIR/bin/gh"

    # Source scanner function definitions (stop before acquire_lock).
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

    # Override paths so run_once does not try to load real projects.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Stub out functions that require real GitHub or project config.
    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    jobs_init_schema() { :; }
    loop_list_slugs() { echo ""; }
    LOOP_JOBS_ENQUEUE=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/stage-age" \
           "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# heartbeat
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file on first tick" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    [ -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}

@test "run_once: updates scanner-heartbeat mtime on subsequent ticks" {
    # Create an old heartbeat file.
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M.%S')" \
        "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null || touch "$LOOP_LOG_DIR/scanner-heartbeat"

    local before
    before=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    sleep 1
    run_once

    local after
    after=$(stat -f%m "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null \
        || stat -c%Y "$LOOP_LOG_DIR/scanner-heartbeat" 2>/dev/null)

    [ "$after" -gt "$before" ]
}

@test "run_once: does not create scanner-heartbeat when DRY_RUN=true" {
    DRY_RUN=true
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run_once
    [ ! -f "$LOOP_LOG_DIR/scanner-heartbeat" ]
}
