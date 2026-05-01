#!/usr/bin/env bats
# tests/scanner.bats — unit tests for stateless logic in scanner/scanner.sh.
# All gh calls are intercepted by the mock binary in test_helper/.
#
# Sourcing strategy: awk extracts all function/variable definitions from
# scanner.sh and stops before the bare "acquire_lock" call that would start
# the daemon loop. SCRIPT_DIR/LOOP_ROOT lines are skipped; LOOP_ROOT is
# injected first so the lib/ source statements resolve correctly.
#
# Note: bash 3.2 (macOS default) does not propagate function definitions from
# `source <(...)` to the caller's scope. We write to a temp file instead.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-gh.sh as the gh binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Pre-set log dir so env.sh does not create ~/.loop/logs during tests.
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    # Source scanner.sh function definitions only.
    # Write to a temp file: bash 3.2 (macOS) does not propagate function
    # definitions from `source <(...)` to the caller's scope.
    # Also strip the arg-parsing for..done block (bats passes test name as $@)
    # and replace with explicit variable assignments.
    # Suppress LOOP_EXTRA_PATH so env.sh does not prepend /opt/homebrew/bin
    # and shadow the mock gh binary we placed in $BATS_TMPDIR/bin.
    export LOOP_EXTRA_PATH=""
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
    # Re-prepend mock bin dir in case env.sh modified PATH.
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Override paths that scanner.sh hard-codes after sourcing.
    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    # Ensure emit uses direct mode with no event-queue client.
    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    # Silence log() output; no-op dispatch_direct to avoid launching handlers.
    log() { :; }
    dispatch_direct() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _dedup_key
# ---------------------------------------------------------------------------

@test "_dedup_key: produces non-empty output" {
    run _dedup_key "loop.dev_issue:owner/repo:42"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "_dedup_key: same input yields same hash" {
    local a b
    a=$(_dedup_key "loop.dev_issue:test-org/test-repo:7")
    b=$(_dedup_key "loop.dev_issue:test-org/test-repo:7")
    [ "$a" = "$b" ]
}

@test "_dedup_key: different inputs yield different hashes" {
    local a b
    a=$(_dedup_key "loop.dev_issue:test-org/test-repo:1")
    b=$(_dedup_key "loop.dev_issue:test-org/test-repo:2")
    [ "$a" != "$b" ]
}

# ---------------------------------------------------------------------------
# _handler_to_event_type
# ---------------------------------------------------------------------------

@test "_handler_to_event_type: dev-handler maps to loop.dev_issue" {
    run _handler_to_event_type "dev-handler"
    [ "$status" -eq 0 ]
    [ "$output" = "loop.dev_issue" ]
}

@test "_handler_to_event_type: po-handler maps to loop.po_review" {
    run _handler_to_event_type "po-handler"
    [ "$status" -eq 0 ]
    [ "$output" = "loop.po_review" ]
}

@test "_handler_to_event_type: review-handler maps to loop.pr_review" {
    run _handler_to_event_type "review-handler"
    [ "$status" -eq 0 ]
    [ "$output" = "loop.pr_review" ]
}

@test "_handler_to_event_type: dev-rework-handler maps to loop.dev_rework" {
    run _handler_to_event_type "dev-rework-handler"
    [ "$status" -eq 0 ]
    [ "$output" = "loop.dev_rework" ]
}

@test "_handler_to_event_type: qa-handler maps to loop.pr_qa" {
    run _handler_to_event_type "qa-handler"
    [ "$status" -eq 0 ]
    [ "$output" = "loop.pr_qa" ]
}

@test "_handler_to_event_type: merge-handler maps to loop.pr_merge" {
    run _handler_to_event_type "merge-handler"
    [ "$status" -eq 0 ]
    [ "$output" = "loop.pr_merge" ]
}

# ---------------------------------------------------------------------------
# author_is_allowed — author allow-list with operator-approved override
# ---------------------------------------------------------------------------

@test "author_is_allowed: allow-listed author passes" {
    export ALLOWED_AUTHORS="alice,bob"
    run author_is_allowed "alice" ""
    [ "$status" -eq 0 ]
}

@test "author_is_allowed: outsider without override is rejected" {
    export ALLOWED_AUTHORS="alice"
    run author_is_allowed "mallory" "dev p2-medium"
    [ "$status" -eq 1 ]
}

@test "author_is_allowed: operator-approved label bypasses gate for outsider" {
    export ALLOWED_AUTHORS="alice"
    run author_is_allowed "mallory" "dev operator-approved"
    [ "$status" -eq 0 ]
}

@test "author_is_allowed: empty ALLOWED_AUTHORS lets everyone through" {
    export ALLOWED_AUTHORS=""
    run author_is_allowed "anyone" ""
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# issue_is_claimed — uses workflow-derived PR stage labels
# ---------------------------------------------------------------------------

@test "issue_is_claimed: returns 0 when issue has in-progress label" {
    export GH_MOCK_OUTPUT="in-progress"
    run issue_is_claimed "test-slug" "owner/repo" 1
    [ "$status" -eq 0 ]
}

@test "issue_is_claimed: returns 0 when issue has needs-review label (default workflow)" {
    export GH_MOCK_OUTPUT="needs-review"
    run issue_is_claimed "test-slug" "owner/repo" 1
    [ "$status" -eq 0 ]
}

@test "issue_is_claimed: returns 0 when issue has qa-pass label" {
    export GH_MOCK_OUTPUT="qa-pass"
    run issue_is_claimed "test-slug" "owner/repo" 1
    [ "$status" -eq 0 ]
}

@test "issue_is_claimed: returns 1 when issue has only dev label" {
    export GH_MOCK_OUTPUT="dev"
    run issue_is_claimed "test-slug" "owner/repo" 1
    [ "$status" -eq 1 ]
}

@test "issue_is_claimed: returns 1 when issue has no labels" {
    export GH_MOCK_OUTPUT=""
    run issue_is_claimed "test-slug" "owner/repo" 1
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# _pr_downstream_labels
# ---------------------------------------------------------------------------

@test "_pr_downstream_labels: default workflow, from needs-review includes rework/qa/merge stages" {
    # No LOOP_CONFIG → resolves to default workflow
    unset LOOP_CONFIG
    run _pr_downstream_labels "test-slug" "needs-review"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs-dev"* ]]
    [[ "$output" == *"needs-qa"* ]]
    [[ "$output" == *"qa-pass"* ]]
}

@test "_pr_downstream_labels: default workflow, from qa-pass excludes upstream stages" {
    unset LOOP_CONFIG
    run _pr_downstream_labels "test-slug" "qa-pass"
    [ "$status" -eq 0 ]
    [[ "$output" != *"needs-review"* ]]
    [[ "$output" != *"needs-dev"* ]]
    [[ "$output" != *"needs-qa"* ]]
}

# ---------------------------------------------------------------------------
# Workflow-fixture tests: 2 projects, 2 workflows (default + minimal)
# Verify that loop_polled_labels returns correct labels per workflow,
# and that scan_project emits correct events per workflow stage.
# ---------------------------------------------------------------------------

# Write a two-project projects.yaml fixture to $BATS_TMPDIR/fixture.yaml
_write_fixture_config() {
    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: proj-default
    name: Default Project
    repo: owner/default-repo
    root: /tmp/fake-default
    default_branch: main
    workflow: default
    dev:
      commit_prefix: DEF
      max_concurrent_prs: 3

  - slug: proj-minimal
    name: Minimal Project
    repo: owner/minimal-repo
    root: /tmp/fake-minimal
    default_branch: main
    workflow: minimal
    dev:
      commit_prefix: MIN
      max_concurrent_prs: 3
YAML
}

@test "workflow fixture: proj-default issue labels include needs-po and needs-dev" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-default" issue
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs-po"* ]]
    [[ "$output" == *"needs-dev"* ]]
}

@test "workflow fixture: proj-minimal issue labels include needs-dev but NOT needs-po" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-minimal" issue
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs-dev"* ]]
    [[ "$output" != *"needs-po"* ]]
}

@test "workflow fixture: proj-default PR labels include needs-review, needs-qa, qa-pass" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-default" pr
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs-review"* ]]
    [[ "$output" == *"needs-qa"* ]]
    [[ "$output" == *"qa-pass"* ]]
}

@test "workflow fixture: proj-minimal PR labels use needs-qa for merge (no review stage)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-minimal" pr
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs-qa"* ]]
    [[ "$output" != *"needs-review"* ]]
}

@test "workflow fixture: proj-default emits loop.dev_issue for dev-labeled issue" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    local PLAN_ISSUE
    PLAN_ISSUE='{"number":1,"title":"Fix thing","url":"http://gh/1","labels":["needs-dev"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        [ "$_label" = "needs-dev" ] && printf '%s\n' "$PLAN_ISSUE"
        return 0
    }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    loop_load_backend()            { return 0; }
    loop_load_project() {
        REPO="owner/default-repo"
        MAX_CONCURRENT_PRS=3
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }

    local emit_log="$BATS_TMPDIR/emit-default.log"
    rm -f "$emit_log"
    emit() { echo "$1" >> "$emit_log"; return 0; }

    scan_project "proj-default"

    [ -f "$emit_log" ]
    grep -q '"type".*"loop\.dev_issue"' "$emit_log"
}

@test "workflow fixture: proj-minimal emits loop.pr_merge for needs-qa PR (no review step)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    local MERGE_PR
    MERGE_PR='{"number":5,"title":"Merge me","url":"http://gh/5","labels":["needs-qa"],"headRefName":"feat/5","mergeable":"MERGEABLE"}'

    backend_list_issues_with_label() { return 0; }
    backend_list_prs_with_label() {
        local _label="$2"
        [ "$_label" = "needs-qa" ] && printf '%s\n' "$MERGE_PR"
        return 0
    }
    backend_list_open_prs_raw()   { echo "[]"; }
    backend_pr_has_any_label()    { return 1; }
    backend_issue_has_any_label() { return 1; }
    loop_load_backend()           { return 0; }
    loop_load_project() {
        REPO="owner/minimal-repo"
        MAX_CONCURRENT_PRS=3
        BACKEND=github
        WORKFLOW=minimal
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }

    local emit_log="$BATS_TMPDIR/emit-minimal.log"
    rm -f "$emit_log"
    emit() { echo "$1" >> "$emit_log"; return 0; }

    scan_project "proj-minimal"

    [ -f "$emit_log" ]
    grep -q '"type".*"loop\.pr_merge"' "$emit_log"
}

# ---------------------------------------------------------------------------
# emit (dedup behavior)
# Calls are made without `run` so function definitions in this scope apply.
# ---------------------------------------------------------------------------

@test "emit: creates dedup key file after dispatch" {
    dispatch_direct() { return 0; }
    export GH_MOCK_OUTPUT=""

    local json='{"type":"loop.dev_issue","payload":{"slug":"test","repo":"owner/repo"}}'
    emit "$json" "dev_issue:owner/repo:10"

    local key
    key=$(_dedup_key "dev_issue:owner/repo:10")
    [ -f "$DEDUP_DIR/$key" ]
}

@test "emit: calls dispatch_direct when no dedup key exists" {
    local dispatch_log="$BATS_TMPDIR/dispatch.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local json='{"type":"loop.dev_issue","payload":{"slug":"test","repo":"owner/repo"}}'
    emit "$json" "dev_issue:owner/repo:11"

    [ -f "$dispatch_log" ]
}

@test "emit: skips dispatch when key file is recent" {
    # stat -f%m is macOS-specific; skip on platforms where it is unavailable.
    local key
    key=$(_dedup_key "dev_issue:owner/repo:12")
    touch "$DEDUP_DIR/$key"
    if ! stat -f%m "$DEDUP_DIR/$key" 2>/dev/null; then
        skip "stat -f%m not available on this platform"
    fi

    local dispatch_log="$BATS_TMPDIR/dispatch2.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local json='{"type":"loop.dev_issue","payload":{}}'
    emit "$json" "dev_issue:owner/repo:12"

    [ ! -f "$dispatch_log" ]
}

@test "emit: no dedup key file created when dedup_id is empty" {
    local dispatch_log="$BATS_TMPDIR/dispatch3.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local before_count
    before_count=$(find "$DEDUP_DIR" -type f | wc -l)

    local json='{"type":"loop.dev_issue","payload":{}}'
    emit "$json" ""

    local after_count
    after_count=$(find "$DEDUP_DIR" -type f | wc -l)
    [ "$before_count" -eq "$after_count" ]
}
