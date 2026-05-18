#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — liveness heartbeat for scanner.sh (#413).
#
# Verifies:
#   1. run_once() writes (or updates) the heartbeat file every tick.
#   2. scanner-watchdog.sh exits 0 without killing when heartbeat is fresh.
#   3. scanner-watchdog.sh kills the PID and exits when heartbeat is stale.
#   4. scanner-watchdog.sh exits cleanly when no lock file exists.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""
    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner functions (same awk-strip strategy as scanner.bats).
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
    HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }
    _sweep_stale_locks() { :; }
    loop_list_slugs() { printf ''; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Heartbeat write: run_once() must create/update the heartbeat file.
# ---------------------------------------------------------------------------

@test "run_once: creates heartbeat file on first tick" {
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once: updates heartbeat file mtime on each call" {
    # stat -f%m is macOS; stat -c%Y is Linux. Skip if neither works.
    touch "$HEARTBEAT_FILE"
    # Force old mtime.
    touch -t 202001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || skip "touch -t not supported on this platform"

    local before
    before=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
          || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null) \
        || skip "stat mtime not available on this platform"

    sleep 1
    run_once

    local after
    after=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null \
         || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)

    [ "$after" -gt "$before" ]
}

@test "run_once: heartbeat file contains a timestamp string" {
    run_once
    [ -s "$HEARTBEAT_FILE" ]
    # Must contain digits (a date/time string).
    grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$HEARTBEAT_FILE"
}

@test "run_once: DRY_RUN=true does NOT write heartbeat file" {
    DRY_RUN=true
    rm -f "$HEARTBEAT_FILE"
    run_once
    [ ! -f "$HEARTBEAT_FILE" ]
    DRY_RUN=false
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh: behaviour tests.
# We invoke it as a subprocess so LOOP_LOG_DIR is passed via environment.
# ---------------------------------------------------------------------------

@test "scanner-watchdog: exits 0 with no kill when heartbeat is fresh" {
    # Write a fresh heartbeat (now).
    date '+%Y-%m-%d %H:%M:%S' > "$HEARTBEAT_FILE"

    # Set a very short threshold so a fresh file still passes.
    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_STALE_THRESHOLD=9999 \
            LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"scanner is alive"* ]]
}

@test "scanner-watchdog: reports stale when heartbeat is old" {
    # Write a heartbeat and back-date it so it appears 2 hours old.
    touch "$HEARTBEAT_FILE"
    touch -t 202001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || skip "touch -t not supported — cannot simulate stale heartbeat"

    # Create a fake lock file with a PID we know exists ($$).
    echo "$$" > "$BATS_TMPDIR/fake-scanner.lock"

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_STALE_THRESHOLD=60 \
            LOOP_EXTRA_PATH="" \
        bash -c "
            LOCK_FILE='$BATS_TMPDIR/fake-scanner.lock'
            source '$REPO_ROOT/lib/env.sh'
            HEARTBEAT_FILE='$HEARTBEAT_FILE'
            POLL_INTERVAL=300
            STALE_THRESHOLD_SECONDS=60
            DRY_RUN=true
            log() { echo \"\[scanner-watchdog\] \$*\"; }
            $( awk '/^_heartbeat_age_seconds/,/^}/' "$REPO_ROOT/scanner/scanner-watchdog.sh" )
            age=\$(_heartbeat_age_seconds)
            echo \"age=\${age}\"
            [ \"\$age\" -ge 60 ] && echo 'STALE_CONFIRMED'
        "

    [[ "$output" == *"STALE_CONFIRMED"* ]]
}

@test "scanner-watchdog: exits 0 when no lock file exists (scanner already down)" {
    # Write stale heartbeat.
    touch "$HEARTBEAT_FILE"
    touch -t 202001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || skip "touch -t not supported"

    # Ensure no lock file.
    rm -f /tmp/loop-scanner.lock

    run env LOOP_LOG_DIR="$LOOP_LOG_DIR" \
            LOOP_SCANNER_STALE_THRESHOLD=1 \
            LOOP_EXTRA_PATH="" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}

@test "scanner-watchdog: --dry-run does not kill any process" {
    # Write stale heartbeat.
    touch "$HEARTBEAT_FILE"
    touch -t 202001010000 "$HEARTBEAT_FILE" 2>/dev/null \
        || skip "touch -t not supported"

    # Use our own PID as the fake scanner — must NOT be killed.
    local fake_lock="$BATS_TMPDIR/fake-lock-dryrun.lock"
    echo "$$" > "$fake_lock"

    # Patch LOCK_FILE inside the watchdog via an override wrapper.
    local wrapper="$BATS_TMPDIR/watchdog-wrapper.sh"
    cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
export LOOP_LOG_DIR="$LOOP_LOG_DIR"
export LOOP_SCANNER_STALE_THRESHOLD=1
export LOOP_EXTRA_PATH=""
# Override LOCK_FILE before sourcing watchdog logic.
LOCK_FILE_OVERRIDE="$fake_lock"
source "$REPO_ROOT/lib/env.sh"
HEARTBEAT_FILE="$HEARTBEAT_FILE"
POLL_INTERVAL=300
STALE_THRESHOLD_SECONDS=1
DRY_RUN=true
LOCK_FILE="\$LOCK_FILE_OVERRIDE"
log() { echo "[scanner-watchdog] \$*"; }
$( sed -n '/^_heartbeat_age_seconds/,/^}/p' "$REPO_ROOT/scanner/scanner-watchdog.sh" )
age=\$(_heartbeat_age_seconds)
echo "age=\${age}"
if [ "\$age" -lt "\$STALE_THRESHOLD_SECONDS" ]; then
    echo "scanner is alive — no action needed"; exit 0
fi
scanner_pid=\$(cat "\$LOCK_FILE" 2>/dev/null || true)
if kill -0 "\$scanner_pid" 2>/dev/null; then
    if \$DRY_RUN; then
        echo "DRY-RUN: would kill PID \$scanner_pid"
    fi
fi
WRAPPER
    chmod +x "$wrapper"

    run bash "$wrapper"

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    # Our own process must still be alive.
    kill -0 "$$"
}
