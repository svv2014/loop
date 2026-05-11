#!/usr/bin/env bats
# tests/reconciler-tracker-close.bats — unit tests for reconcile_tracker_issues
# in scanner/reconciler.sh. Sources reconciler.sh in lib-only mode, mocks `gh`
# for the tracker listing + per-child state lookup, and stubs the backend
# helpers so we can assert on close / comment / emit calls.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOOP_MONITOR_URL=""
    export SLUG="test-slug"

    # MOCK_TRACKERS_JSON  → returned for `gh issue list --label tracker`
    # MOCK_EPICS_JSON     → returned for `gh issue list --label epic`
    # MOCK_CHILD_STATES   → "num=STATE,num=STATE" lookup table for `gh issue view`
    export MOCK_TRACKERS_JSON='[]'
    export MOCK_EPICS_JSON='[]'
    export MOCK_CHILD_STATES=""

    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Stubbed `gh`: supports `issue list --label X` and `issue view N --json state`.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
    label=""
    for ((i=3; i<=$#; i++)); do
        if [ "${!i}" = "--label" ]; then
            j=$((i+1)); label="${!j}"
        fi
    done
    case "$label" in
        tracker) printf '%s\n' "${MOCK_TRACKERS_JSON:-[]}" ;;
        epic)    printf '%s\n' "${MOCK_EPICS_JSON:-[]}"    ;;
        *)       printf '%s\n' "[]" ;;
    esac
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    num="$3"
    # MOCK_CHILD_STATES looks like "1=CLOSED,2=OPEN"
    IFS=',' read -ra pairs <<< "${MOCK_CHILD_STATES:-}"
    for p in "${pairs[@]}"; do
        key="${p%%=*}"; val="${p#*=}"
        if [ "$key" = "$num" ]; then
            printf '%s\n' "$val"
            exit 0
        fi
    done
    printf '%s\n' "OPEN"
    exit 0
fi
exit 0
GHEOF
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    backend_comment_issue() { echo "comment $2 :: $3" >> "$OPS_LOG"; }
    backend_close_issue()   { echo "close $2"        >> "$OPS_LOG"; }
    _loop_emit_event()      { echo "emit_event $1 $2" >> "$OPS_LOG"; }
    log()                   { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" "$OPS_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Happy path: tracker with two closed children → close + comment + emit
# ---------------------------------------------------------------------------

@test "reconcile_tracker_issues: tracker with all children closed gets closed" {
    export MOCK_TRACKERS_JSON='[{
        "number": 10,
        "title": "Q2 cleanup tracker",
        "labels": [{"name":"tracker"}],
        "body": "Children:\n- [x] #1\n- [x] #2\n"
    }]'
    export MOCK_CHILD_STATES="1=CLOSED,2=CLOSED"

    run reconcile_tracker_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "close 10"            "$OPS_LOG"
    grep -q "comment 10 ::"       "$OPS_LOG"
    grep -q "emit_event tracker_closed" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Mixed children: one open → no close
# ---------------------------------------------------------------------------

@test "reconcile_tracker_issues: tracker with one open child is left alone" {
    export MOCK_TRACKERS_JSON='[{
        "number": 20,
        "title": "Mixed tracker",
        "labels": [{"name":"tracker"}],
        "body": "- [x] #5\n- [ ] #6\n"
    }]'
    export MOCK_CHILD_STATES="5=CLOSED,6=OPEN"

    run reconcile_tracker_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "close 20|comment 20|tracker_closed" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# No parseable children → no action
# ---------------------------------------------------------------------------

@test "reconcile_tracker_issues: tracker without parseable children is skipped" {
    export MOCK_TRACKERS_JSON='[{
        "number": 30,
        "title": "Empty tracker",
        "labels": [{"name":"tracker"}],
        "body": "This is just prose with no issue references at all."
    }]'

    run reconcile_tracker_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "close 30|comment 30|tracker_closed" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Checkbox '[x]' is a hint only — trust the real state, which is OPEN
# ---------------------------------------------------------------------------

@test "reconcile_tracker_issues: checkbox '[x]' but real state is OPEN → no close" {
    export MOCK_TRACKERS_JSON='[{
        "number": 40,
        "title": "Stale-checkbox tracker",
        "labels": [{"name":"tracker"}],
        "body": "- [x] #9\n"
    }]'
    # Operator ticked the box but the issue is actually still open.
    export MOCK_CHILD_STATES="9=OPEN"

    run reconcile_tracker_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "close 40|comment 40|tracker_closed" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Opt-out via env
# ---------------------------------------------------------------------------

@test "reconcile_tracker_issues: LOOP_AUTO_CLOSE_TRACKERS=false disables the sweep" {
    export LOOP_AUTO_CLOSE_TRACKERS=false
    export MOCK_TRACKERS_JSON='[{
        "number": 50,
        "title": "Would-be closed tracker",
        "labels": [{"name":"tracker"}],
        "body": "- [x] #1\n- [x] #2\n"
    }]'
    export MOCK_CHILD_STATES="1=CLOSED,2=CLOSED"

    run reconcile_tracker_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || [ ! -s "$OPS_LOG" ] || ! grep -qE "close 50|comment 50|tracker_closed" "$OPS_LOG"
}
