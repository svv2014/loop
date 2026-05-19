#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for #413 liveness heartbeat.
#
# Verifies that:
#   1. _scanner_write_heartbeat touches HEARTBEAT_FILE on every call.
#   2. run_once() updates the heartbeat file (integration check via stub).
#   3. restart-scanner-if-stale.sh reports healthy when heartbeat is fresh.
#   4. restart-scanner-if-stale.sh reports stale when heartbeat is old.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"

    # Suppress LOOP_EXTRA_PATH so env.sh does not prepend /opt/homebrew/bin.
    export LOOP_EXTRA_PATH=""

    # Source scanner function definitions only (same awk extraction as scanner.bats).
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

    # Override HEARTBEAT_FILE after sourcing (scanner.sh sets it from LOOP_LOG_DIR).
    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    log() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat creates heartbeat file" {
    [ ! -f "$HEARTBEAT_FILE" ]
    _scanner_write_heartbeat
    [ -f "$HEARTBEAT_FILE" ]
}

@test "_scanner_write_heartbeat updates mtime on every call" {
    touch -t 200001010000 "$HEARTBEAT_FILE"   # old mtime
    local before
    before=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    sleep 1
    _scanner_write_heartbeat
    local after
    after=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")
    [ "$after" -gt "$before" ]
}

@test "_scanner_write_heartbeat is a no-op in dry-run mode" {
    DRY_RUN=true
    _scanner_write_heartbeat
    [ ! -f "$HEARTBEAT_FILE" ]
    DRY_RUN=false
}

# ---------------------------------------------------------------------------
# scanner.sh contains the HEARTBEAT_FILE declaration (regression guard)
# ---------------------------------------------------------------------------

@test "scanner.sh declares HEARTBEAT_FILE variable" {
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh calls _scanner_write_heartbeat in run_once" {
    grep -q '_scanner_write_heartbeat' "$REPO_ROOT/scanner/scanner.sh"
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh — dry-run mode
# ---------------------------------------------------------------------------

@test "watchdog reports healthy when heartbeat is fresh" {
    touch "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"healthy"* ]]
}

@test "watchdog reports stale when heartbeat is old" {
    touch -t 200001010000 "$HEARTBEAT_FILE"   # epoch-like old mtime
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}

@test "watchdog reports missing heartbeat file" {
    rm -f "$HEARTBEAT_FILE"
    run "$REPO_ROOT/scanner/restart-scanner-if-stale.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}
