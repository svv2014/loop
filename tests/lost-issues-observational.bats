#!/usr/bin/env bats
# tests/lost-issues-observational.bats — coverage for reconcile_lost_issues.
#
# Verifies the post-#214 behaviour:
#   - LOST issues trigger a Signal notification (loop_notify called)
#   - LOST issues DO NOT mutate state (no backend_add_label, no
#     backend_comment_issue) — this was the root cause of every label
#     ping-pong incident on 2026-05-01 (proj-x#10 41 comments,
#     ppl-study#421 80 comments).
#   - Per-(repo, issue) cool-down suppresses a second Signal within
#     LOOP_LOST_NOTIFY_HOURS.
#
# Sourcing pattern: set LOOP_RECONCILER_LIB_ONLY=1 so reconciler.sh
# defines functions and returns without acquiring locks or running main.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Per-test cool-down dir so test runs are isolated.
    export LOOP_LOST_STATE_DIR="$BATS_TMPDIR/lost-notified-$$"
    rm -rf "$LOOP_LOST_STATE_DIR"

    # Operations log: every backend_add_label / backend_comment_issue /
    # loop_notify call records a line. Tests assert on the contents.
    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    # Globals reconciler.sh expects to exist at top-level scope.
    export REPO="owner/test-repo"
    export DRY_RUN=false

    # Library-only mode: source reconciler.sh without running main.
    export LOOP_RECONCILER_LIB_ONLY=1

    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Override stubbed-out functions AFTER sourcing so they win over any
    # real implementation pulled in via lib/*.
    backend_add_label()         { echo "backend_add_label $*"         >> "$OPS_LOG"; }
    backend_remove_label()      { echo "backend_remove_label $*"      >> "$OPS_LOG"; }
    backend_comment_issue()     { echo "backend_comment_issue $*"     >> "$OPS_LOG"; }
    backend_comment_pr()        { echo "backend_comment_pr $*"        >> "$OPS_LOG"; }
    loop_notify()               { echo "loop_notify $*"               >> "$OPS_LOG"; }
    # Default: no closing PR. Tests that need one set BACKEND_PR_FOR_ISSUE.
    backend_find_pr_for_issue() { echo "${BACKEND_PR_FOR_ISSUE:-}"; }

    # Mock gh: only the `gh issue list` call inside reconcile_lost_issues
    # needs a return value. Read fixture from $GH_FIXTURE.
    gh() {
        if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
            cat "${GH_FIXTURE:-/dev/null}"
            return 0
        fi
        return 0
    }
    export -f gh
}

teardown() {
    rm -rf "$LOOP_LOST_STATE_DIR" "$OPS_LOG"
    unset GH_FIXTURE BACKEND_PR_FOR_ISSUE
}

# Helper: fixture for an issue with no pipeline labels at all.
write_fixture_unlabelled_issue() {
    GH_FIXTURE="$BATS_TMPDIR/fixture-unlabelled.json"
    cat > "$GH_FIXTURE" <<'JSON'
[
    {"number": 42, "title": "Test ticket without pipeline label", "labels": [{"name": "p2-medium"}]}
]
JSON
    export GH_FIXTURE
}

# Helper: fixture for an issue WITH a pipeline label (should not be lost).
write_fixture_labelled_issue() {
    GH_FIXTURE="$BATS_TMPDIR/fixture-labelled.json"
    cat > "$GH_FIXTURE" <<'JSON'
[
    {"number": 99, "title": "Healthy ticket", "labels": [{"name": "needs-po"}, {"name": "p1-high"}]}
]
JSON
    export GH_FIXTURE
}

# ─── Tests ───────────────────────────────────────────────────────────────────

@test "lost issue: notifies operator (Signal) but does NOT mutate state" {
    write_fixture_unlabelled_issue

    run reconcile_lost_issues "$REPO"
    [ "$status" -eq 0 ]

    # Mutation must NOT happen — this is the root-cause fix for the ping-pong.
    ! grep -q "^backend_add_label"     "$OPS_LOG"
    ! grep -q "^backend_comment_issue" "$OPS_LOG"

    # Operator notification IS expected.
    grep -q "^loop_notify .*#42" "$OPS_LOG"
    grep -q "Test ticket without pipeline label" "$OPS_LOG"
}

@test "labelled issue: no notification, no mutation (not lost)" {
    write_fixture_labelled_issue

    run reconcile_lost_issues "$REPO"
    [ "$status" -eq 0 ]

    # Nothing happens for a healthy ticket.
    [ ! -s "$OPS_LOG" ] || ! grep -qE "^(backend_add_label|backend_comment_issue|loop_notify)" "$OPS_LOG"
}

@test "lost issue cool-down: second tick within window does NOT re-notify" {
    write_fixture_unlabelled_issue

    # Tick 1 — should notify.
    reconcile_lost_issues "$REPO"
    local notifies_after_1
    notifies_after_1=$(grep -c "^loop_notify" "$OPS_LOG" || echo 0)
    [ "$notifies_after_1" -eq 1 ]

    # Tick 2 — within LOOP_LOST_NOTIFY_HOURS (default 24h); cool-down kicks in.
    reconcile_lost_issues "$REPO"
    local notifies_after_2
    notifies_after_2=$(grep -c "^loop_notify" "$OPS_LOG" || echo 0)
    [ "$notifies_after_2" -eq 1 ]   # still 1 — second tick was suppressed
}

@test "lost issue cool-down: re-notifies after the window expires" {
    write_fixture_unlabelled_issue

    # Tick 1 — notify and create the sentinel.
    reconcile_lost_issues "$REPO"

    # Backdate the sentinel beyond the cool-down window so the next tick
    # treats it as expired.
    local repo_slug="${REPO//\//-}"
    local sentinel="$LOOP_LOST_STATE_DIR/${repo_slug}-42"
    [ -f "$sentinel" ]
    # Set mtime to 25h ago (default LOOP_LOST_NOTIFY_HOURS=24).
    touch -t "$(date -v-25H '+%Y%m%d%H%M' 2>/dev/null || date -d '25 hours ago' '+%Y%m%d%H%M')" "$sentinel"

    # Tick 2 — should notify again.
    reconcile_lost_issues "$REPO"
    local notifies
    notifies=$(grep -c "^loop_notify" "$OPS_LOG" || echo 0)
    [ "$notifies" -eq 2 ]
}

@test "DRY_RUN=true: still classifies but does nothing — no notify, no sentinel" {
    write_fixture_unlabelled_issue
    DRY_RUN=true

    run reconcile_lost_issues "$REPO"
    [ "$status" -eq 0 ]

    # No mutating ops, no notification, no sentinel created.
    ! grep -q "^backend_add_label"     "$OPS_LOG" 2>/dev/null
    ! grep -q "^backend_comment_issue" "$OPS_LOG" 2>/dev/null
    ! grep -q "^loop_notify"           "$OPS_LOG" 2>/dev/null
    [ ! -d "$LOOP_LOST_STATE_DIR" ] || [ -z "$(ls "$LOOP_LOST_STATE_DIR" 2>/dev/null)" ]

    DRY_RUN=false
}

@test "lost issue WITH open closing PR: skipped silently — no Signal (#199 producer/consumer pair)" {
    write_fixture_unlabelled_issue
    BACKEND_PR_FOR_ISSUE=99   # closing PR exists

    run reconcile_lost_issues "$REPO"
    [ "$status" -eq 0 ]

    # No mutating ops AND no notification — operator already sees the PR.
    ! grep -q "^backend_add_label"     "$OPS_LOG" 2>/dev/null
    ! grep -q "^backend_comment_issue" "$OPS_LOG" 2>/dev/null
    ! grep -q "^loop_notify"           "$OPS_LOG" 2>/dev/null

    # No sentinel either — we'll re-evaluate freshly next tick.
    [ ! -f "$LOOP_LOST_STATE_DIR/owner-test-repo-42" ]
}
