#!/usr/bin/env bats
# tests/reconciler-orphan-issues.bats — unit tests for reconcile_orphan_issues
# in scanner/reconciler.sh. Sources reconciler.sh in lib-only mode so only
# function definitions are loaded, then exercises the sweep with stubbed
# backends + a mocked `gh` for issue listing.

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
    export ALLOWED_AUTHORS=""

    export MOCK_ISSUES_JSON='[]'

    export LOOP_EXTRA_PATH=""

    LOOP_RECONCILER_LIB_ONLY=1
    set --
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    # Fake `gh` so `gh issue list ... --json ...` returns our fixture.
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Only the `issue list` subcommand is exercised here. Echo the fixture.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
    printf '%s\n' "${MOCK_ISSUES_JSON:-[]}"
    exit 0
fi
exit 0
GHEOF
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    backend_add_label() { echo "add_label $2 $3" >> "$OPS_LOG"; }
    _loop_emit_event()  { echo "emit_event $1" >> "$OPS_LOG"; }
    log()               { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" "$OPS_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Happy path: issue with only a priority label gets needs-po
# ---------------------------------------------------------------------------

@test "reconcile_orphan_issues: open issue with only p1-high gets needs-po added" {
    export MOCK_ISSUES_JSON='[{
        "number": 42,
        "title": "Refactor auth flow",
        "labels": [{"name": "p1-high"}],
        "author": {"login": "alice"}
    }]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "add_label 42 needs-po" "$OPS_LOG"
    grep -q "emit_event auto_labeled_needs_po" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# No-op: issue already labelled needs-clarification
# ---------------------------------------------------------------------------

@test "reconcile_orphan_issues: issue with needs-clarification is left alone" {
    export MOCK_ISSUES_JSON='[{
        "number": 99,
        "title": "Awaiting product input",
        "labels": [{"name": "needs-clarification"}],
        "author": {"login": "alice"}
    }]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label 99|emit_event" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Skip rules: trigger labels, epic / tracker, author gating, opt-out
# ---------------------------------------------------------------------------

@test "reconcile_orphan_issues: issue already carrying needs-dev is skipped" {
    export MOCK_ISSUES_JSON='[{
        "number": 7,
        "title": "Has a trigger already",
        "labels": [{"name": "needs-dev"}],
        "author": {"login": "alice"}
    }]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label 7" "$OPS_LOG"
}

@test "reconcile_orphan_issues: epic / tracker tickets are skipped" {
    export MOCK_ISSUES_JSON='[
        {"number": 100, "title": "Epic umbrella", "labels": [{"name": "epic"}], "author": {"login": "alice"}},
        {"number": 101, "title": "Tracker board",  "labels": [{"name": "tracker"}], "author": {"login": "alice"}}
    ]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label 100|add_label 101" "$OPS_LOG"
}

@test "reconcile_orphan_issues: outside author is skipped when ALLOWED_AUTHORS is set" {
    export ALLOWED_AUTHORS="alice"
    export MOCK_ISSUES_JSON='[{
        "number": 55,
        "title": "From outsider",
        "labels": [],
        "author": {"login": "mallory"}
    }]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label 55" "$OPS_LOG"
}

@test "reconcile_orphan_issues: operator-approved label bypasses author gate" {
    export ALLOWED_AUTHORS="alice"
    export MOCK_ISSUES_JSON='[{
        "number": 56,
        "title": "From outsider but approved",
        "labels": [{"name": "operator-approved"}],
        "author": {"login": "mallory"}
    }]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    grep -q "add_label 56 needs-po" "$OPS_LOG"
}

@test "reconcile_orphan_issues: LOOP_AUTO_NEEDS_PO=false disables the sweep" {
    export LOOP_AUTO_NEEDS_PO=false
    export MOCK_ISSUES_JSON='[{
        "number": 77,
        "title": "Would-be orphan",
        "labels": [{"name": "p2-medium"}],
        "author": {"login": "alice"}
    }]'

    run reconcile_orphan_issues "$REPO" "$SLUG"
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || [ ! -s "$OPS_LOG" ] || ! grep -qE "add_label 77" "$OPS_LOG"
}
