#!/usr/bin/env bats
# tests/notify_human_required.bats — coverage for loop_notify_human_required.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/loop-notify-test-$$"
    mkdir -p "$LOOP_LOG_DIR"
    export NOTIFY_LOG="$BATS_TMPDIR/loop-notify-msgs-$$"
    : > "$NOTIFY_LOG"
    # shellcheck source=../lib/notify.sh
    source "$REPO_ROOT/lib/notify.sh"

    # Override loop_notify so the test captures messages instead of evaluating
    # the LOOP_NOTIFY command fragment.
    loop_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }

    # Stub backend_issue_view so the helper has title/url/comment data.
    backend_issue_view() {
        local field
        for field in "$@"; do
            case "$field" in
                title)    echo "Sample issue title"; return 0 ;;
                url)      echo "https://example.test/issue/1"; return 0 ;;
                comments) echo ""; return 0 ;;
            esac
        done
        echo ""
    }
    export -f backend_issue_view 2>/dev/null || true
}

teardown() {
    rm -rf "$LOOP_LOG_DIR" "$NOTIFY_LOG"
}

@test "fires once on first transition" {
    export LOOP_NOTIFY_CHANNEL="signal"
    loop_notify_human_required "demo" 42 needs-clarification "ambiguous spec"
    [ -s "$NOTIFY_LOG" ]
    grep -q "demo" "$NOTIFY_LOG"
    grep -q "#42" "$NOTIFY_LOG"
    grep -q "needs-clarification" "$NOTIFY_LOG"
    [ -f "$LOOP_LOG_DIR/notified/demo-42-needs-clarification" ]
}

@test "second tick same day is a no-op" {
    export LOOP_NOTIFY_CHANNEL="signal"
    loop_notify_human_required "demo" 7 blocked "first"
    local first_count
    first_count=$(wc -l < "$NOTIFY_LOG")
    loop_notify_human_required "demo" 7 blocked "second"
    local second_count
    second_count=$(wc -l < "$NOTIFY_LOG")
    [ "$first_count" = "$second_count" ]
}

@test "missing LOOP_NOTIFY_CHANNEL is silent" {
    unset LOOP_NOTIFY_CHANNEL
    run loop_notify_human_required "demo" 9 blocked "no channel"
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
    [ ! -f "$LOOP_LOG_DIR/notified/demo-9-blocked" ]
}

@test "notifier failure does not exit caller" {
    export LOOP_NOTIFY_CHANNEL="signal"
    # Make the underlying notifier fail hard.
    loop_notify() { return 7; }
    set -e
    loop_notify_human_required "demo" 11 blocked "notifier broken"
    local rc=$?
    [ "$rc" -eq 0 ]
    # Caller continues running afterwards.
    echo "still alive"
}

@test "clear removes dedup file so future transition re-fires" {
    export LOOP_NOTIFY_CHANNEL="signal"
    loop_notify_human_required "demo" 5 blocked "first"
    [ -f "$LOOP_LOG_DIR/notified/demo-5-blocked" ]
    loop_notify_human_required_clear "demo" 5 blocked
    [ ! -f "$LOOP_LOG_DIR/notified/demo-5-blocked" ]
    loop_notify_human_required "demo" 5 blocked "second"
    [ "$(wc -l < "$NOTIFY_LOG")" -ge 2 ]
}
