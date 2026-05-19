#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — verify scanner writes a heartbeat file on each tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""
    export LOOP_ROOT="$REPO_ROOT"

    # Stub mock gh binary.
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    export HEARTBEAT_FILE
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs"
}

@test "scanner.sh defines HEARTBEAT_FILE pointing to LOOP_LOG_DIR" {
    grep -q 'HEARTBEAT_FILE=' "$REPO_ROOT/scanner/scanner.sh"
    grep -q 'scanner-heartbeat' "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh touches HEARTBEAT_FILE in run_once" {
    grep -q 'touch.*HEARTBEAT_FILE' "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner-watchdog.sh exits 0 when heartbeat is fresh" {
    # Create a fresh heartbeat file.
    touch "$LOOP_LOG_DIR/scanner-heartbeat"

    # Run watchdog in dry-run so it does not attempt kills.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"fresh"* ]]
}

@test "scanner-watchdog.sh reports stale heartbeat when mtime is old" {
    # Create a heartbeat file and backdate its mtime by 1 hour.
    touch "$LOOP_LOG_DIR/scanner-heartbeat"
    python3 -c "
import os, time
p = '$LOOP_LOG_DIR/scanner-heartbeat'
t = time.time() - 3600
os.utime(p, (t, t))
"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]] || [[ "$output" == *"wedged"* ]]
}

@test "scanner-watchdog.sh exits 0 when heartbeat file is missing" {
    rm -f "$LOOP_LOG_DIR/scanner-heartbeat"
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
        LOOP_SCANNER_INTERVAL=300 \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no heartbeat"* ]]
}
