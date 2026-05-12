#!/usr/bin/env bats
# tests/reconciler-stuck-in-review.bats
#
# Tests for reconcile_stuck_in_review in scanner/reconciler.sh.
# Sources reconciler.sh in LOOP_RECONCILER_LIB_ONLY=1 mode so only function
# definitions are loaded; stubs backends so no real GitHub calls are made.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    export COMMENT_LOG="$BATS_TMPDIR/comment.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG"

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export STUCK_IN_REVIEW_MINUTES=60

    export LOOP_EXTRA_PATH=""
    export LOOP_CONFIG=""
    export LOOP_MONITOR_URL=""

    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Stub functions used by reconcile_stuck_in_review.
    backend_remove_label() { echo "remove $2 $3" >> "$OPS_LOG"; }
    backend_add_label()    { echo "add $2 $3"    >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment $2"   >> "$COMMENT_LOG"; }
    loop_notify()          { :; }
    log()                  { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$OPS_LOG" "$COMMENT_LOG" 2>/dev/null || true
}

# Produce an updatedAt timestamp N minutes in the past (ISO 8601 UTC).
_minutes_ago_ts() {
    local n="$1"
    python3 -c "
import datetime as dt
ago = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=$n)
print(ago.strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

# ---------------------------------------------------------------------------
# Test 1: PR with stale in-review (>60min) → stripped and needs-review added
# ---------------------------------------------------------------------------

@test "reconcile_stuck_in_review: stale in-review PR is recovered to needs-review" {
    local stale_ts
    stale_ts=$(_minutes_ago_ts 90)

    export MOCK_PRS_JSON="[{
        \"number\": 7,
        \"title\": \"Fix the auth flow\",
        \"labels\": [{\"name\": \"in-review\"}],
        \"updatedAt\": \"$stale_ts\"
    }]"

    backend_list_open_prs_raw() { printf '%s\n' "${MOCK_PRS_JSON:-[]}"; }

    run reconcile_stuck_in_review "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove 7 in-review"   "$OPS_LOG"
    grep -q "add 7 needs-review"   "$OPS_LOG"
    grep -q "comment 7"            "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Test 2: PR with fresh in-review (<60min) → NOT touched
# ---------------------------------------------------------------------------

@test "reconcile_stuck_in_review: fresh in-review PR is left alone" {
    local fresh_ts
    fresh_ts=$(_minutes_ago_ts 10)

    export MOCK_PRS_JSON="[{
        \"number\": 8,
        \"title\": \"Another PR\",
        \"labels\": [{\"name\": \"in-review\"}],
        \"updatedAt\": \"$fresh_ts\"
    }]"

    backend_list_open_prs_raw() { printf '%s\n' "${MOCK_PRS_JSON:-[]}"; }

    run reconcile_stuck_in_review "$REPO"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || ! grep -q "remove\|add" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 3: stale in-review but terminal label also set → NOT touched
# ---------------------------------------------------------------------------

@test "reconcile_stuck_in_review: stale in-review with needs-rework — skipped" {
    local stale_ts
    stale_ts=$(_minutes_ago_ts 120)

    # PR has in-review AND needs-rework — decision already made, cleanup in progress.
    export MOCK_PRS_JSON="[{
        \"number\": 9,
        \"title\": \"PR with terminal label\",
        \"labels\": [{\"name\": \"in-review\"}, {\"name\": \"needs-rework\"}],
        \"updatedAt\": \"$stale_ts\"
    }]"

    backend_list_open_prs_raw() { printf '%s\n' "${MOCK_PRS_JSON:-[]}"; }

    run reconcile_stuck_in_review "$REPO"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || ! grep -q "remove\|add" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 4: no PRs at all → no-op
# ---------------------------------------------------------------------------

@test "reconcile_stuck_in_review: empty PR list — no-op" {
    backend_list_open_prs_raw() { echo "[]"; }

    run reconcile_stuck_in_review "$REPO"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || ! grep -q "." "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 5: --dry-run flag — logs but does NOT mutate labels
# ---------------------------------------------------------------------------

@test "reconcile_stuck_in_review: dry-run does not mutate labels" {
    local stale_ts
    stale_ts=$(_minutes_ago_ts 90)

    export MOCK_PRS_JSON="[{
        \"number\": 11,
        \"title\": \"Dry run test PR\",
        \"labels\": [{\"name\": \"in-review\"}],
        \"updatedAt\": \"$stale_ts\"
    }]"

    backend_list_open_prs_raw() { printf '%s\n' "${MOCK_PRS_JSON:-[]}"; }

    DRY_RUN=true run reconcile_stuck_in_review "$REPO"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || ! grep -q "remove\|add" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 6: configurable threshold — STUCK_IN_REVIEW_MINUTES=30
# ---------------------------------------------------------------------------

@test "reconcile_stuck_in_review: respects custom STUCK_IN_REVIEW_MINUTES threshold" {
    export STUCK_IN_REVIEW_MINUTES=30
    local stale_ts
    stale_ts=$(_minutes_ago_ts 45)

    export MOCK_PRS_JSON="[{
        \"number\": 12,
        \"title\": \"PR past custom threshold\",
        \"labels\": [{\"name\": \"in-review\"}],
        \"updatedAt\": \"$stale_ts\"
    }]"

    backend_list_open_prs_raw() { printf '%s\n' "${MOCK_PRS_JSON:-[]}"; }

    run reconcile_stuck_in_review "$REPO"
    [ "$status" -eq 0 ]

    grep -q "remove 12 in-review"  "$OPS_LOG"
    grep -q "add 12 needs-review"  "$OPS_LOG"
}
