#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat liveness mechanism tests.
#
# 1. Verifies scanner.sh touches ${LOOP_LOG_DIR}/scanner-heartbeat on each tick.
# 2. Verifies scanner-watchdog.sh correctly classifies fresh vs stale heartbeats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs"
}

# ---------------------------------------------------------------------------
# scanner.sh — source-level guard
# ---------------------------------------------------------------------------

@test "scanner.sh touches scanner-heartbeat inside run_once" {
    grep -q "scanner-heartbeat" "$REPO_ROOT/scanner/scanner.sh"
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — fresh heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 and reports healthy when heartbeat is fresh" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    LOOP_SCANNER_WATCHDOG_THRESHOLD=600 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "healthy" ]]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — missing heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 when heartbeat file is absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "no heartbeat" ]]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh — stale heartbeat, no live scanner
# ---------------------------------------------------------------------------

@test "scanner-watchdog: reports ALERT when heartbeat is stale" {
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    # Backdate the heartbeat so it looks 30 min old.
    touch -t "$(date -v-30M '+%Y%m%d%H%M.%S' 2>/dev/null \
             || date -d '30 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
             || echo '197001010000.00')" \
        "$LOOP_LOG_DIR/scanner-heartbeat"
    # Use a 60 s threshold so any file older than 1 min triggers.
    LOOP_SCANNER_WATCHDOG_THRESHOLD=60 \
        run "$REPO_ROOT/scanner/scanner-watchdog.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ALERT" ]]
}
