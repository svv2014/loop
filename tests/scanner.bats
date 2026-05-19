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

# Regression: the default workflow uses `needs-dev` as the issue dev trigger
# AND as the PR rework trigger. Before the fix, issue_is_claimed naively
# treated every PR-trigger label as a claim and silently filtered out any
# issue that had its own dev trigger — the dev handler never fired, the
# pipeline stalled after PO. The fix subtracts issue triggers from the
# PR-trigger set used for the claim check.
@test "issue_is_claimed: returns 1 when default-workflow issue has only needs-dev (its own dev trigger)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    export GH_MOCK_OUTPUT="needs-dev"
    run issue_is_claimed "proj-default" "owner/default-repo" 1
    [ "$status" -eq 1 ]
}

# Sanity: a real PR-only stage label still counts as a claim.
@test "issue_is_claimed: returns 0 when default-workflow issue has needs-review (PR-only stage)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    export GH_MOCK_OUTPUT="needs-review"
    run issue_is_claimed "proj-default" "owner/default-repo" 1
    [ "$status" -eq 0 ]
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

@test "workflow fixture: proj-default issue labels include loop:action:po and loop:action:dev" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-default" issue
    [ "$status" -eq 0 ]
    [[ "$output" == *"loop:action:po"* ]]
    [[ "$output" == *"loop:action:dev"* ]]
}

@test "workflow fixture: proj-minimal issue labels include loop:action:dev but NOT loop:action:po" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-minimal" issue
    [ "$status" -eq 0 ]
    [[ "$output" == *"loop:action:dev"* ]]
    [[ "$output" != *"loop:action:po"* ]]
}

@test "workflow fixture: proj-default PR labels include loop:action:review, loop:action:qa, loop:result:qa-pass" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-default" pr
    [ "$status" -eq 0 ]
    [[ "$output" == *"loop:action:review"* ]]
    [[ "$output" == *"loop:action:qa"* ]]
    [[ "$output" == *"loop:result:qa-pass"* ]]
}

@test "workflow fixture: proj-minimal PR labels use loop:action:qa for merge (no review stage)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
    run loop_polled_labels "proj-minimal" pr
    [ "$status" -eq 0 ]
    [[ "$output" == *"loop:action:qa"* ]]
    [[ "$output" != *"loop:action:review"* ]]
}

@test "workflow fixture: proj-default emits loop.dev_issue for dev-labeled issue" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    local PLAN_ISSUE
    PLAN_ISSUE='{"number":1,"title":"Fix thing","url":"http://gh/1","labels":["loop:action:dev"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        [ "$_label" = "loop:action:dev" ] && printf '%s\n' "$PLAN_ISSUE"
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

@test "workflow fixture: proj-minimal emits loop.pr_merge for loop:action:qa PR (no review step)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    local MERGE_PR
    MERGE_PR='{"number":5,"title":"Merge me","url":"http://gh/5","labels":["loop:action:qa"],"headRefName":"feat/5","mergeable":"MERGEABLE"}'

    backend_list_issues_with_label() { return 0; }
    backend_list_prs_with_label() {
        local _label="$2"
        [ "$_label" = "loop:action:qa" ] && printf '%s\n' "$MERGE_PR"
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

@test "emit: second identical event within 30-minute window is suppressed" {
    local dispatch_log="$BATS_TMPDIR/dispatch-dedup.log"
    rm -f "$dispatch_log"
    dispatch_direct() { echo "dispatched" >> "$dispatch_log"; return 0; }

    local json='{"type":"loop.dev_issue","payload":{"slug":"test","repo":"owner/repo"}}'
    emit "$json" "dev_issue:owner/repo:99"
    emit "$json" "dev_issue:owner/repo:99"

    local count
    count=$(wc -l < "$dispatch_log" 2>/dev/null | tr -d ' ')
    [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# _sort_rows_by_priority — priority-aware candidate ordering
# ---------------------------------------------------------------------------

@test "_sort_rows_by_priority: p1 sorts before p2 and p3, unlabeled is last" {
    local out
    out=$(printf '%s\n%s\n%s\n%s\n' \
        '{"number":3,"labels":["p3-low"]}' \
        '{"number":1,"labels":["p1-high"]}' \
        '{"number":4,"labels":[]}' \
        '{"number":2,"labels":["p2-medium"]}' \
        | _sort_rows_by_priority)
    local first second third fourth
    first=$(echo  "$out" | sed -n '1p')
    second=$(echo "$out" | sed -n '2p')
    third=$(echo  "$out" | sed -n '3p')
    fourth=$(echo "$out" | sed -n '4p')
    [[ "$first"  == *'"number":1'* ]]
    [[ "$second" == *'"number":2'* ]]
    [[ "$third"  == *'"number":3'* ]]
    [[ "$fourth" == *'"number":4'* ]]
}

@test "_sort_rows_by_priority: p0-critical wins over p1-high; lower number tiebreaks" {
    local out
    out=$(printf '%s\n%s\n%s\n' \
        '{"number":10,"labels":["p1-high"]}' \
        '{"number":7,"labels":["p1-high"]}' \
        '{"number":99,"labels":["p0-critical"]}' \
        | _sort_rows_by_priority)
    [[ "$(echo "$out" | sed -n '1p')" == *'"number":99'*  ]]
    [[ "$(echo "$out" | sed -n '2p')" == *'"number":7'*   ]]
    [[ "$(echo "$out" | sed -n '3p')" == *'"number":10'*  ]]
}

@test "priority-aware scanner: mixed p1/p2/p3 candidates → dev_issue emits p1 first" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    local R1 R2 R3
    R1='{"number":11,"title":"low","url":"http://gh/11","labels":["loop:action:dev","p3-low"],"author":"bot"}'
    R2='{"number":12,"title":"med","url":"http://gh/12","labels":["loop:action:dev","p2-medium"],"author":"bot"}'
    R3='{"number":13,"title":"high","url":"http://gh/13","labels":["loop:action:dev","p1-high"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        if [ "$_label" = "loop:action:dev" ]; then
            printf '%s\n%s\n%s\n' "$R1" "$R2" "$R3"
        fi
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
        MAX_CONCURRENT_PRS=1
        PIPELINE_SLOTS=""
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }

    local emit_log="$BATS_TMPDIR/emit-prio.log"
    rm -f "$emit_log"
    emit() { echo "$1" >> "$emit_log"; return 0; }

    scan_project "proj-default"

    [ -f "$emit_log" ]
    # MAX_CONCURRENT_PRS=1 means exactly one emit; it must be the p1-high (#13).
    local lines
    lines=$(wc -l < "$emit_log" | tr -d ' ')
    [ "$lines" -eq 1 ]
    grep -q '"issue_number": 13' "$emit_log"
}

# ---------------------------------------------------------------------------
# pipeline_slots — serial-mode gate
# ---------------------------------------------------------------------------

@test "pipeline_slots=1 + in-flight ticket: scanner emits nothing at first stage" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # Use proj-minimal so the first issue trigger is `needs-dev` and there is
    # no PO stage to confound the test.
    local NEW_ISSUE INFLIGHT_ISSUE
    NEW_ISSUE='{"number":21,"title":"fresh","url":"http://gh/21","labels":["needs-dev"],"author":"bot"}'
    INFLIGHT_ISSUE='{"number":20,"title":"old","url":"http://gh/20","labels":["in-progress"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        case "$_label" in
            needs-dev)   printf '%s\n' "$NEW_ISSUE" ;;
            in-progress) printf '%s\n' "$INFLIGHT_ISSUE" ;;
        esac
        return 0
    }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    loop_load_backend()            { return 0; }
    loop_load_project() {
        REPO="owner/minimal-repo"
        MAX_CONCURRENT_PRS=3
        PIPELINE_SLOTS=1
        BACKEND=github
        WORKFLOW=minimal
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }

    local emit_log="$BATS_TMPDIR/emit-serial.log"
    rm -f "$emit_log"
    emit() { echo "$1" >> "$emit_log"; return 0; }

    scan_project "proj-minimal"

    # Either the emit log was never created or it has zero entries.
    if [ -f "$emit_log" ]; then
        local lines
        lines=$(wc -l < "$emit_log" | tr -d ' ')
        [ "$lines" -eq 0 ]
    fi
}

# Regression for #267 follow-up: a backlog of issues sitting at the
# first-stage trigger (e.g. 6 tickets at `needs-po`) used to count against
# the pipeline_slots gate, deadlocking the very stage that would drain
# them. Fix: the first-stage trigger is excluded from in-flight counting.
@test "pipeline_slots=1 + 6 needs-po tickets + 0 inflight: scanner emits ONE po claim (#267)" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # 6 issues all sitting at loop:action:po (the first-stage trigger for
    # proj-default). Before the fix these counted as in-flight=6 and the
    # gate skipped all po claims. After the fix in-flight excludes the
    # first-stage trigger and the gate lets one through.
    local I1 I2 I3 I4 I5 I6
    I1='{"number":1,"title":"a","url":"http://gh/1","labels":["loop:action:po"],"author":"bot"}'
    I2='{"number":2,"title":"b","url":"http://gh/2","labels":["loop:action:po"],"author":"bot"}'
    I3='{"number":3,"title":"c","url":"http://gh/3","labels":["loop:action:po"],"author":"bot"}'
    I4='{"number":4,"title":"d","url":"http://gh/4","labels":["loop:action:po"],"author":"bot"}'
    I5='{"number":5,"title":"e","url":"http://gh/5","labels":["loop:action:po"],"author":"bot"}'
    I6='{"number":6,"title":"f","url":"http://gh/6","labels":["loop:action:po"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        if [ "$_label" = "loop:action:po" ]; then
            printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$I1" "$I2" "$I3" "$I4" "$I5" "$I6"
        fi
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
        PIPELINE_SLOTS=1
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }

    local emit_log="$BATS_TMPDIR/emit-po-backlog.log"
    rm -f "$emit_log"
    emit() { echo "$1" >> "$emit_log"; return 0; }

    scan_project "proj-default"

    [ -f "$emit_log" ]
    local lines
    lines=$(wc -l < "$emit_log" | tr -d ' ')
    [ "$lines" -eq 1 ]
    grep -q '"type".*"loop\.po_review"' "$emit_log"
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

# ---------------------------------------------------------------------------
# acquire_lock — atomic noclobber locking
# ---------------------------------------------------------------------------

# Verify that a second scanner invocation exits immediately (without emitting)
# when the lock file already holds a live PID.
# Strategy: invoke scanner.sh --dry-run with a pre-written lock file whose PID
# is our current test process ($$) — guaranteed alive. The scanner must detect
# the live holder and exit 0 without printing any "DRY-RUN emit:" lines.
@test "acquire_lock: exits 0 without dispatching when live PID holds the lock" {
    local lock_file="/tmp/loop-scanner.lock"
    # Write our own PID as the holder — it is guaranteed to be alive.
    echo "$$" > "$lock_file"

    # Run the full scanner script in --dry-run mode. It should detect the live
    # PID and exit 0 without emitting anything.
    run "$REPO_ROOT/scanner/scanner.sh" --dry-run

    # Always clean up the lock file we created.
    rm -f "$lock_file"

    [ "$status" -eq 0 ]
    # Confirm no events were dispatched.
    [[ "$output" != *"DRY-RUN emit:"* ]]
}

# ---------------------------------------------------------------------------
# _scan_has_open_pr_for_issue — dup-PR guard helper (PR #364 / issue #362)
# ---------------------------------------------------------------------------

@test "_scan_has_open_pr_for_issue: returns PR number when body has 'Closes #N'" {
    export GH_MOCK_OUTPUT='[{"number":42,"body":"Closes #99\nSome details"}]'
    export GH_MOCK_EXIT=0
    run _scan_has_open_pr_for_issue "owner/repo" "99"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "_scan_has_open_pr_for_issue: case-insensitive — 'fixes #N' matches" {
    export GH_MOCK_OUTPUT='[{"number":7,"body":"fixes #5 bug in auth"}]'
    export GH_MOCK_EXIT=0
    run _scan_has_open_pr_for_issue "owner/repo" "5"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

@test "_scan_has_open_pr_for_issue: case-insensitive — 'Resolves #N' matches" {
    export GH_MOCK_OUTPUT='[{"number":15,"body":"Resolves #10"}]'
    export GH_MOCK_EXIT=0
    run _scan_has_open_pr_for_issue "owner/repo" "10"
    [ "$status" -eq 0 ]
    [ "$output" = "15" ]
}

@test "_scan_has_open_pr_for_issue: no false positive — 'Closes #123' does NOT match issue #12" {
    export GH_MOCK_OUTPUT='[{"number":50,"body":"Closes #123"}]'
    export GH_MOCK_EXIT=0
    run _scan_has_open_pr_for_issue "owner/repo" "12"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_scan_has_open_pr_for_issue: returns nothing and exits 1 when no PR body matches" {
    export GH_MOCK_OUTPUT='[{"number":3,"body":"No closing reference here"}]'
    export GH_MOCK_EXIT=0
    run _scan_has_open_pr_for_issue "owner/repo" "99"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_scan_has_open_pr_for_issue: fails open when gh exits non-zero" {
    export GH_MOCK_OUTPUT=""
    export GH_MOCK_EXIT=1
    run _scan_has_open_pr_for_issue "owner/repo" "99"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Heartbeat — scanner-heartbeat file updated on every tick (#413)
# ---------------------------------------------------------------------------

@test "run_once: heartbeat file is created/updated on each tick" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # Minimal stubs so run_once completes without network calls.
    loop_list_slugs()              { echo "proj-minimal"; }
    loop_load_project()            {
        REPO="owner/minimal-repo"
        MAX_CONCURRENT_PRS=3
        PIPELINE_SLOTS=""
        BACKEND=github
        WORKFLOW=minimal
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }
    loop_load_backend()            { return 0; }
    loop_project_is_paused()       { return 1; }
    backend_list_issues_with_label() { return 0; }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    jobs_init_schema()             { return 0; }
    _sweep_stale_locks()           { return 0; }
    emit()                         { return 0; }

    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"
    rm -f "$heartbeat_file"

    run_once

    [ -f "$heartbeat_file" ]
}

@test "run_once: heartbeat mtime advances between ticks" {
    _write_fixture_config
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    loop_list_slugs()              { return 0; }
    loop_load_backend()            { return 0; }
    loop_project_is_paused()       { return 1; }
    jobs_init_schema()             { return 0; }
    _sweep_stale_locks()           { return 0; }

    local heartbeat_file="$LOOP_LOG_DIR/scanner-heartbeat"

    # First tick
    run_once
    local mtime1
    mtime1=$(stat -f%m "$heartbeat_file" 2>/dev/null || stat -c%Y "$heartbeat_file" 2>/dev/null || echo 0)

    # Force mtime to be older so a second touch is detectable even within the same second.
    touch -t 200001010000 "$heartbeat_file" 2>/dev/null || true

    # Second tick
    run_once
    local mtime2
    mtime2=$(stat -f%m "$heartbeat_file" 2>/dev/null || stat -c%Y "$heartbeat_file" 2>/dev/null || echo 0)

    [ "$mtime2" -gt "$mtime1" ] || [ "$mtime2" -ne 0 ]
}
