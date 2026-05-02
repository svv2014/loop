#!/usr/bin/env bats
# tests/agent-distress.bats — coverage for reconcile_agent_distress (#203).
#
# Verifies: distress phrases in agent comments → Signal once with cool-down;
# non-distress comments / non-agent authors → no Signal; observational only.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export LOOP_DISTRESS_STATE_DIR="$BATS_TMPDIR/distress-notified-$$"
    rm -rf "$LOOP_DISTRESS_STATE_DIR"

    export ALLOWED_AUTHORS="testagent"
    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOG_FILE="$LOOP_LOG_DIR/loop-reconciler.log"

    export LOOP_RECONCILER_LIB_ONLY=1
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    loop_notify() { echo "loop_notify $*" >> "$OPS_LOG"; }

    # Stub gh: search returns the candidate set; issue view returns fixture.
    gh() {
        if [ "$1" = "search" ] && [ "$2" = "issues" ]; then
            cat "${GH_SEARCH_FIXTURE:-/dev/null}"
            return 0
        fi
        if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
            cat "${GH_VIEW_FIXTURE:-/dev/null}"
            return 0
        fi
        return 0
    }
    export -f gh
}

teardown() {
    rm -rf "$LOOP_DISTRESS_STATE_DIR" "$OPS_LOG" "$LOG_FILE"
    unset GH_SEARCH_FIXTURE GH_VIEW_FIXTURE
}

write_search_fixture() {
    GH_SEARCH_FIXTURE="$BATS_TMPDIR/search.json"
    cat > "$GH_SEARCH_FIXTURE" <<'JSON'
[{"number": 42}]
JSON
    export GH_SEARCH_FIXTURE
}

write_view_with_distress() {
    GH_VIEW_FIXTURE="$BATS_TMPDIR/view-distress.json"
    cat > "$GH_VIEW_FIXTURE" <<'JSON'
{"comments": [
    {"author": {"login": "testagent"}, "body": "PO: pipeline reconciler keeps stripping the dev label every 20 minutes. Human action required."}
]}
JSON
    export GH_VIEW_FIXTURE
}

write_view_no_distress() {
    GH_VIEW_FIXTURE="$BATS_TMPDIR/view-clean.json"
    cat > "$GH_VIEW_FIXTURE" <<'JSON'
{"comments": [
    {"author": {"login": "testagent"}, "body": "PO: tracker decomposed into 3 child issues."}
]}
JSON
    export GH_VIEW_FIXTURE
}

write_view_distress_wrong_author() {
    GH_VIEW_FIXTURE="$BATS_TMPDIR/view-wrong-author.json"
    cat > "$GH_VIEW_FIXTURE" <<'JSON'
{"comments": [
    {"author": {"login": "external-user"}, "body": "Why does the reconciler keep stripping my labels?? Human action required please."}
]}
JSON
    export GH_VIEW_FIXTURE
}

@test "agent posts distress phrase: Signal fires once" {
    write_search_fixture
    write_view_with_distress

    run reconcile_agent_distress "$REPO"
    [ "$status" -eq 0 ]

    grep -q "^loop_notify .*#42.*reconciler keeps" "$OPS_LOG"
}

@test "agent posts non-distress: no Signal" {
    write_search_fixture
    write_view_no_distress

    run reconcile_agent_distress "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "^loop_notify" "$OPS_LOG"
}

@test "non-agent author posts distress phrase: no Signal (only ALLOWED_AUTHORS count)" {
    write_search_fixture
    write_view_distress_wrong_author

    run reconcile_agent_distress "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "^loop_notify" "$OPS_LOG"
}

@test "cool-down: second tick within window does NOT re-Signal" {
    write_search_fixture
    write_view_with_distress

    reconcile_agent_distress "$REPO"
    local notifies1
    notifies1=$(grep -c "^loop_notify" "$OPS_LOG" 2>/dev/null || echo 0)
    [ "$notifies1" -eq 1 ]

    reconcile_agent_distress "$REPO"
    local notifies2
    notifies2=$(grep -c "^loop_notify" "$OPS_LOG" 2>/dev/null || echo 0)
    [ "$notifies2" -eq 1 ]
}

@test "DRY_RUN=true: detect but do not Signal" {
    write_search_fixture
    write_view_with_distress
    DRY_RUN=true

    reconcile_agent_distress "$REPO"

    [ ! -s "$OPS_LOG" ] || ! grep -q "^loop_notify" "$OPS_LOG"
    DRY_RUN=false
}

@test "no recently-updated tickets: no-op, no error" {
    GH_SEARCH_FIXTURE="$BATS_TMPDIR/empty-search.json"
    echo "[]" > "$GH_SEARCH_FIXTURE"
    export GH_SEARCH_FIXTURE

    run reconcile_agent_distress "$REPO"
    [ "$status" -eq 0 ]
    [ ! -s "$OPS_LOG" ]
}
