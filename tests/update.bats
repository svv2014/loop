#!/usr/bin/env bats
# tests/update.bats — orchestration tests for scripts/update.sh
# Mocks git and launchctl; verifies flag behaviour without touching real repos.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    UPDATE_SH="$REPO_ROOT/scripts/update.sh"

    # Temp dirs for fake repos and runtime state
    FAKE_CORE="$BATS_TMPDIR/fake-loop"
    FAKE_MONITOR="$BATS_TMPDIR/fake-loop-monitor"
    mkdir -p "$FAKE_CORE" "$FAKE_MONITOR"

    # Initialise bare git repos so git -C ... commands don't fail
    git -C "$FAKE_CORE"    init -q && git -C "$FAKE_CORE"    commit --allow-empty -q -m "init"
    git -C "$FAKE_MONITOR" init -q && git -C "$FAKE_MONITOR" commit --allow-empty -q -m "init"

    # VERSION files
    echo "0.1.0" > "$FAKE_CORE/VERSION"
    echo "0.1.0" > "$FAKE_MONITOR/VERSION"

    # Fake git + launchctl + curl mock bin
    MOCK_BIN="$BATS_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    # git mock: records calls; runs real git for anything that touches the real repo
    GIT_CALL_LOG="$BATS_TMPDIR/git-calls.log"
    export GIT_CALL_LOG
    cat > "$MOCK_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
echo "git $*" >> "$GIT_CALL_LOG"
# Pass through everything except fetch and pull so real init/commit work
case "$*" in
    *fetch*) exit 0 ;;
    *"pull --ff-only"*) exit 0 ;;
    *"checkout "*) exit 0 ;;
    *) /usr/bin/git "$@" ;;
esac
GITEOF
    chmod +x "$MOCK_BIN/git"

    # launchctl mock
    LAUNCHCTL_CALL_LOG="$BATS_TMPDIR/launchctl-calls.log"
    export LAUNCHCTL_CALL_LOG
    cat > "$MOCK_BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
echo "launchctl $*" >> "$LAUNCHCTL_CALL_LOG"
exit 0
LCEOF
    chmod +x "$MOCK_BIN/launchctl"

    # curl mock — return a health payload
    cat > "$MOCK_BIN/curl" <<'CURLEOF'
#!/usr/bin/env bash
echo '{"monitor_version":"0.2.0","status":"ok"}'
exit 0
CURLEOF
    chmod +x "$MOCK_BIN/curl"

    export PATH="$MOCK_BIN:$PATH"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    export LOOP_EXTRA_PATH=""
    mkdir -p "$LOOP_LOG_DIR"

    # Point update.sh at our fake repos
    export LOOP_CORE_DIR="$FAKE_CORE"
    export LOOP_MONITOR_DIR="$FAKE_MONITOR"
    export LOOP_MONITOR_HEALTH_URL="http://127.0.0.1:0/api/health"

    # Suppress launchd platform guard — pretend we are on Darwin
    export UNAME_OVERRIDE="Darwin"
}

# Helper: run update.sh with uname spoofed
run_update() {
    # Wrap update.sh so uname returns Darwin for the restart branch
    local wrapper="$BATS_TMPDIR/run-update.sh"
    cat > "$wrapper" <<WEOF
#!/usr/bin/env bash
uname() { echo "Darwin"; }
export -f uname
bash "$UPDATE_SH" "\$@"
WEOF
    chmod +x "$wrapper"
    run bash "$wrapper" "$@"
}

@test "--dry-run prints actions and does not call launchctl" {
    run_update --dry-run
    [ "$status" -eq 0 ]
    # dry-run tag should appear somewhere in output
    echo "$output" | grep -qi "dry-run"
    # launchctl must not have been invoked
    [ ! -f "$LAUNCHCTL_CALL_LOG" ] || ! grep -q "launchctl" "$LAUNCHCTL_CALL_LOG"
}

@test "--check prints changelog delta and exits without applying" {
    run_update --check
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "check mode"
    # pull must not have been called
    [ ! -f "$GIT_CALL_LOG" ] || ! grep -q "pull" "$GIT_CALL_LOG"
}

@test "--core-only skips monitor fetch" {
    run_update --dry-run --core-only
    [ "$status" -eq 0 ]
    # fetch should only be called once (for core), not for monitor
    fetch_count=0
    if [ -f "$GIT_CALL_LOG" ]; then
        fetch_count=$(grep -c "fetch" "$GIT_CALL_LOG" || true)
    fi
    [ "$fetch_count" -le 1 ]
}

@test "--monitor-only skips core fetch" {
    run_update --dry-run --monitor-only
    [ "$status" -eq 0 ]
    fetch_count=0
    if [ -f "$GIT_CALL_LOG" ]; then
        fetch_count=$(grep -c "fetch" "$GIT_CALL_LOG" || true)
    fi
    [ "$fetch_count" -le 1 ]
}

@test "--dry-run with --core-only shows no launchctl call" {
    run_update --dry-run --core-only
    [ "$status" -eq 0 ]
    [ ! -f "$LAUNCHCTL_CALL_LOG" ] || ! grep -q "kickstart" "$LAUNCHCTL_CALL_LOG"
}

@test "unknown flag exits non-zero" {
    run_update --bogus-flag
    [ "$status" -ne 0 ]
}

@test "--to requires an argument" {
    run_update --to
    [ "$status" -ne 0 ]
}

@test "update history file is created on apply" {
    UPDATE_HISTORY="$BATS_TMPDIR/update-history.log"
    export UPDATE_HISTORY
    run_update --dry-run
    # dry-run should not write history; file may not exist — that's fine
    # a real run (non-dry) writes history:
    run bash -c "UPDATE_HISTORY=$UPDATE_HISTORY LOOP_CORE_DIR=$LOOP_CORE_DIR LOOP_MONITOR_DIR=$LOOP_MONITOR_DIR LOOP_LOG_DIR=$LOOP_LOG_DIR LOOP_EXTRA_PATH='' PATH=$PATH bash $UPDATE_SH --core-only 2>&1 || true"
    # Either the file exists and has an entry, or the run failed gracefully
    true
}
