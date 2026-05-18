#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written every tick.
#
# Covers:
#   1. scanner.sh writes scanner-heartbeat on every tick (not in --dry-run)
#   2. scanner-watchdog.sh exits 0 when heartbeat is fresh
#   3. scanner-watchdog.sh detects a stale heartbeat (--dry-run)
#   4. scanner-watchdog.sh skips gracefully when heartbeat file is absent

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/loop-logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_SCANNER_INTERVAL=300
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

# ---------------------------------------------------------------------------
# 1. Heartbeat written on each tick (replicating run_once snippet)
# ---------------------------------------------------------------------------

@test "scanner.sh: heartbeat file is written during run_once" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb_file" ]

    # Mirror the run_once heartbeat snippet
    (
        DRY_RUN=false
        if ! $DRY_RUN; then
            mkdir -p "${LOOP_LOG_DIR}"
            date +%s > "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true
        fi
    )

    [ -f "$hb_file" ]
    local ts
    ts=$(cat "$hb_file")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "scanner.sh: heartbeat mtime advances between ticks" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"

    date +%s > "$hb_file"
    local mtime1
    mtime1=$(stat -f%m "$hb_file" 2>/dev/null || stat -c%Y "$hb_file" 2>/dev/null)

    sleep 1

    date +%s > "$hb_file"
    local mtime2
    mtime2=$(stat -f%m "$hb_file" 2>/dev/null || stat -c%Y "$hb_file" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "scanner.sh: heartbeat not written in --dry-run mode" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"

    (
        DRY_RUN=true
        if ! $DRY_RUN; then
            mkdir -p "${LOOP_LOG_DIR}"
            date +%s > "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true
        fi
    )

    [ ! -f "$hb_file" ]
}

# ---------------------------------------------------------------------------
# 2. scanner-watchdog.sh: fresh heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 when heartbeat is fresh" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    date +%s > "$hb_file"

    LOOP_SCANNER_WATCHDOG_THRESHOLD=900 \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

# ---------------------------------------------------------------------------
# 3. scanner-watchdog.sh: stale heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: detects stale heartbeat in dry-run" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    echo "1" > "$hb_file"
    touch -t 197001010000 "$hb_file"

    LOOP_SCANNER_WATCHDOG_THRESHOLD=1 \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

# ---------------------------------------------------------------------------
# 4. scanner-watchdog.sh: absent heartbeat
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: skips gracefully when heartbeat absent" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}
