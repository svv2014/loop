#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner heartbeat behaviour.
#
# Sourcing strategy mirrors tests/scanner.bats: awk extracts function/variable
# definitions, stops before the bare "acquire_lock" call, and injects LOOP_ROOT
# so lib/ sources resolve.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Mock gh and python3 dependencies via a per-test bin dir.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Source scanner functions (same awk extraction used in scanner.bats).
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

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() and no-op dispatch_direct so run_once completes without side effects.
    log() { :; }
    dispatch_direct() { :; }

    # Stub out scan_project so run_once doesn't try to iterate real projects.
    loop_list_slugs() { echo ""; }
    jobs_init_schema() { return 0; }
    _sweep_stale_locks() { return 0; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-hb-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat: run_once must touch ${LOOP_LOG_DIR}/scanner-heartbeat
# ---------------------------------------------------------------------------

@test "run_once: creates scanner-heartbeat file on first tick" {
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb_file" ]

    run_once

    [ -f "$hb_file" ]
}

@test "run_once: updates scanner-heartbeat mtime on every tick" {
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    # Create the file with an old timestamp.
    touch -t 200001010000 "$hb_file" 2>/dev/null \
        || touch "$hb_file"

    local before_mtime
    before_mtime=$(stat -f%m "$hb_file" 2>/dev/null \
        || stat -c%Y "$hb_file" 2>/dev/null \
        || echo 0)

    # Sleep 1s to guarantee a mtime difference on filesystems with 1s granularity.
    sleep 1

    run_once

    local after_mtime
    after_mtime=$(stat -f%m "$hb_file" 2>/dev/null \
        || stat -c%Y "$hb_file" 2>/dev/null \
        || echo 0)

    [ "$after_mtime" -gt "$before_mtime" ]
}

@test "run_once: does NOT create scanner-heartbeat in dry-run mode" {
    DRY_RUN=true
    local hb_file="${LOOP_LOG_DIR}/scanner-heartbeat"
    [ ! -f "$hb_file" ]

    run_once

    [ ! -f "$hb_file" ]
}
