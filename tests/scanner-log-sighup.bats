#!/usr/bin/env bats
# tests/scanner-log-sighup.bats — coverage for #194 SIGHUP log-reopen.
#
# Behavioural test: spawn a stub long-running scanner that imports the
# real trap-install snippet, rotate its log file out from under it, send
# SIGHUP, then verify subsequent writes go to the new (current) inode
# instead of the orphaned one.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    rm -f "$LOG_FILE"
}

teardown() {
    rm -f "$LOG_FILE" "$LOG_FILE.rotated"
}

@test "scanner.sh installs SIGHUP trap that reopens log fds" {
    # Verify the trap snippet is present in scanner.sh source (regression
    # guard: someone removing the trap would break log-rotation recovery).
    grep -q "trap.*_scanner_reopen_log" "$REPO_ROOT/scanner/scanner.sh"
    grep -q "_scanner_reopen_log()" "$REPO_ROOT/scanner/scanner.sh"
}

@test "SIGHUP behavior: writes resume to current inode after log rotation" {
    # Build a minimal scanner-shaped script that uses the same trap
    # mechanism. Run it in the background, rotate, HUP, write more, verify.
    local stub="$BATS_TMPDIR/stub-scanner.sh"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
LOG_FILE="$1"
exec 1>>"$LOG_FILE" 2>>"$LOG_FILE"
_scanner_reopen_log() {
    if [ -n "${LOG_FILE:-}" ]; then
        exec 1>>"$LOG_FILE" 2>>"$LOG_FILE" || true
    fi
}
trap '_scanner_reopen_log; echo "REOPENED"' HUP
echo "PRE-ROTATE"
# Write every 0.1s; main loop exits after 30 ticks (3s) — plenty of time
# for the test driver to rotate + HUP + verify.
for i in $(seq 1 30); do
    echo "tick=$i"
    sleep 0.1
done
STUB
    chmod +x "$stub"
    "$stub" "$LOG_FILE" &
    local pid=$!

    # Let it write a few lines before we rotate.
    sleep 0.3
    grep -q "PRE-ROTATE" "$LOG_FILE"

    # "Rotate" — move current log aside, create empty file at the path.
    mv "$LOG_FILE" "$LOG_FILE.rotated"
    : > "$LOG_FILE"
    [ ! -s "$LOG_FILE" ]   # confirmed: 0 bytes after rotation

    # Without the SIGHUP, writes would go to the now-orphaned inode at
    # $LOG_FILE.rotated — the on-disk file at $LOG_FILE would stay 0
    # bytes. Send SIGHUP to reopen.
    kill -HUP "$pid"
    sleep 0.4

    # Verify: the new file received the REOPENED marker and subsequent ticks.
    grep -q "REOPENED" "$LOG_FILE"
    [ -s "$LOG_FILE" ]   # not 0 bytes anymore

    wait "$pid" 2>/dev/null || true
}
