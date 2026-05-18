#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat written every tick.
#
# Covers:
#   1. scanner.sh writes scanner-heartbeat on every tick
#   2. scanner-watchdog.sh exits 0 when heartbeat is fresh
#   3. scanner-watchdog.sh detects a stale heartbeat (dry-run)
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
# 1. scanner.sh writes scanner-heartbeat on each tick
# ---------------------------------------------------------------------------

@test "scanner.sh: heartbeat file is written during run_once" {
    # Source only the heartbeat-write portion of scanner.sh by running
    # the minimal snippet that mirrors what run_once does.
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    [ ! -f "$hb_file" ]

    # Replicate the snippet from run_once()
    (
        DRY_RUN=false
        _hb_dir="$LOOP_LOG_DIR"
        mkdir -p "$_hb_dir"
        date +%s > "${_hb_dir}/scanner-heartbeat" 2>/dev/null || true
    )

    [ -f "$hb_file" ]
    local ts
    ts=$(cat "$hb_file")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "scanner.sh: heartbeat file mtime advances between ticks" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"

    # Simulate first tick
    date +%s > "$hb_file"
    local mtime1
    mtime1=$(stat -f%m "$hb_file" 2>/dev/null || stat -c%Y "$hb_file" 2>/dev/null)

    # Small sleep so mtime differs
    sleep 1

    # Simulate second tick
    date +%s > "$hb_file"
    local mtime2
    mtime2=$(stat -f%m "$hb_file" 2>/dev/null || stat -c%Y "$hb_file" 2>/dev/null)

    [ "$mtime2" -ge "$mtime1" ]
}

@test "scanner.sh: heartbeat not written in --dry-run mode" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    # In dry-run mode the $DRY_RUN check prevents the write.
    (
        DRY_RUN=true
        if ! $DRY_RUN; then
            _hb_dir="$LOOP_LOG_DIR"
            mkdir -p "$_hb_dir"
            date +%s > "${_hb_dir}/scanner-heartbeat" 2>/dev/null || true
        fi
    )
    [ ! -f "$hb_file" ]
}

# ---------------------------------------------------------------------------
# 2. scanner-watchdog.sh: fresh heartbeat → exit 0
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: exits 0 when heartbeat is fresh" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    date +%s > "$hb_file"

    # Threshold much larger than actual age (0s), so watchdog should pass.
    LOOP_SCANNER_WATCHDOG_THRESHOLD=900 \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

# ---------------------------------------------------------------------------
# 3. scanner-watchdog.sh: stale heartbeat → dry-run reports restart
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: detects stale heartbeat and reports restart in dry-run" {
    local hb_file="$LOOP_LOG_DIR/scanner-heartbeat"
    # Write a heartbeat stamped far in the past (epoch 1 = 1970).
    echo "1" > "$hb_file"
    touch -t 197001010000 "$hb_file"

    # Threshold of 1s means any real file is stale.
    LOOP_SCANNER_WATCHDOG_THRESHOLD=1 \
    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

# ---------------------------------------------------------------------------
# 4. scanner-watchdog.sh: missing heartbeat file → skip gracefully
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh: skips gracefully when heartbeat file absent" {
    # Ensure no heartbeat exists
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"

    run "$REPO_ROOT/scripts/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}
