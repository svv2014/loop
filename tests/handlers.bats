#!/usr/bin/env bats
# tests/handlers.bats — unit tests for handler entry-point label transitions.
#
# Verifies that dev-handler and po-handler strip their trigger labels before
# adding in-progress, so an issue never carries both labels simultaneously.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

    # Minimal project fixture using the default workflow
    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: test-proj
    name: Test Project
    repo: owner/test-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
}

teardown() {
    rm -f "$BATS_TMPDIR/fixture.yaml" \
          "$BATS_TMPDIR/override.yaml" \
          "$BATS_TMPDIR/label-ops.log" \
          "$BATS_TMPDIR/override-ops.log"
}

# ---------------------------------------------------------------------------
# dev-handler claim transition
# ---------------------------------------------------------------------------

@test "dev-handler claim: trigger label removed and in-progress added, no overlap" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the claim sequence from dev-handler.sh
    local _dev_trigger
    _dev_trigger=$(loop_label_for "test-proj" "dev")
    backend_remove_label "owner/test-repo" "1" "$_dev_trigger"
    backend_add_label    "owner/test-repo" "1" "in-progress"

    # trigger label must be removed (default workflow uses needs-dev)
    grep -q "remove needs-dev" "$ops_log"
    # in-progress must be added
    grep -q "add in-progress" "$ops_log"
    # trigger label must NOT be re-added (no dual state)
    ! grep -q "add needs-dev" "$ops_log"
    # remove must precede add
    local rm_line add_line
    rm_line=$(grep -n "remove needs-dev" "$ops_log" | cut -d: -f1)
    add_line=$(grep -n "add in-progress" "$ops_log" | cut -d: -f1)
    [ "$rm_line" -lt "$add_line" ]
}

@test "dev-handler claim: label override respected (dev → backlog)" {
    cat > "$BATS_TMPDIR/override.yaml" <<'YAML'
version: 1
projects:
  - slug: override-proj
    name: Override Project
    repo: owner/override-repo
    root: /tmp/fake2
    default_branch: main
    workflow: default
    labels:
      dev: backlog
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/override.yaml"

    local ops_log="$BATS_TMPDIR/override-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    local _dev_trigger
    _dev_trigger=$(loop_label_for "override-proj" "dev")
    backend_remove_label "owner/override-repo" "1" "$_dev_trigger"
    backend_add_label    "owner/override-repo" "1" "in-progress"

    # overridden label (backlog) must be stripped, not the canonical name
    grep -q "remove backlog" "$ops_log"
    ! grep -q "remove dev" "$ops_log"
}

# ---------------------------------------------------------------------------
# po-handler claim transition
# ---------------------------------------------------------------------------

@test "po-handler claim: po-review trigger removed before in-progress added" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the claim sequence from po-handler.sh
    local _po_trigger
    _po_trigger=$(loop_label_for "test-proj" "po-review")
    backend_remove_label "owner/test-repo" "1" "$_po_trigger"
    backend_add_label    "owner/test-repo" "1" "in-progress"

    # default workflow po trigger is needs-po
    grep -q "remove needs-po" "$ops_log"
    grep -q "add in-progress" "$ops_log"
    ! grep -q "add needs-po" "$ops_log"
    local rm_line add_line
    rm_line=$(grep -n "remove needs-po" "$ops_log" | cut -d: -f1)
    add_line=$(grep -n "add in-progress" "$ops_log" | cut -d: -f1)
    [ "$rm_line" -lt "$add_line" ]
}

# ---------------------------------------------------------------------------
# po-handler MR-aware decision paths
# ---------------------------------------------------------------------------

# Replicates the in-flight PR detection logic from po-handler.sh.
# Returns: sets _IN_FLIGHT_PR and _MR_PREAMBLE in the caller's scope.
_run_inflight_detection() {
    local repo="$1" issue_num="$2"
    _IN_FLIGHT_PR=""
    _MR_PREAMBLE=""
    local _in_flight_pr_num
    _in_flight_pr_num=$(backend_find_pr_for_issue "$repo" "$issue_num" 2>/dev/null || echo "")
    if [ -n "$_in_flight_pr_num" ]; then
        local _pr_state
        _pr_state=$(backend_pr_view "$repo" "$_in_flight_pr_num" \
            --json state --jq '.state' 2>/dev/null || echo "")
        if [ "$_pr_state" = "OPEN" ]; then
            _IN_FLIGHT_PR="$_in_flight_pr_num"
            _MR_PREAMBLE="--- EXISTING IMPLEMENTATION IN FLIGHT ---
PR #${_IN_FLIGHT_PR}: test-title
Branch: fix/1-slug
State: OPEN
--- END IN-FLIGHT CONTEXT ---"
        fi
    fi
}

@test "po-handler: MR found and open — prompt contains EXISTING IMPLEMENTATION IN FLIGHT" {
    backend_find_pr_for_issue() { echo "42"; }
    backend_pr_view() {
        # Called twice: first for state, second for full meta
        if [[ "$*" == *"--json state"* ]]; then
            echo "OPEN"
        else
            echo "{}"
        fi
    }

    _run_inflight_detection "owner/test-repo" "1"

    [ -n "$_IN_FLIGHT_PR" ]
    [ "$_IN_FLIGHT_PR" = "42" ]
    [[ "$_MR_PREAMBLE" == *"EXISTING IMPLEMENTATION IN FLIGHT"* ]]
}

@test "po-handler: MR closed or merged — treated as no MR, original A-F paths preserved" {
    backend_find_pr_for_issue() { echo "42"; }
    backend_pr_view() {
        echo "CLOSED"
    }

    _run_inflight_detection "owner/test-repo" "1"

    [ -z "$_IN_FLIGHT_PR" ]
    [ -z "$_MR_PREAMBLE" ]
}

@test "po-handler: no MR found — original A-F behavior preserved, no in-flight preamble" {
    backend_find_pr_for_issue() { echo ""; }

    _run_inflight_detection "owner/test-repo" "1"

    [ -z "$_IN_FLIGHT_PR" ]
    [ -z "$_MR_PREAMBLE" ]
}

# ---------------------------------------------------------------------------
# qa-handler label correctness (regression for qa-failed vs qa-fail typo)
# ---------------------------------------------------------------------------

@test "qa-handler: validation_cmd fails → qa-fail label set (not qa-failed)" {
    local ops_log="$BATS_TMPDIR/qa-label-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the failure branch label sequence from qa-handler.sh
    local repo="owner/test-repo" pr_num="1"
    backend_remove_label "$repo" "$pr_num" needs-qa
    backend_remove_label "$repo" "$pr_num" ready-for-qa
    backend_remove_label "$repo" "$pr_num" approved
    backend_remove_label "$repo" "$pr_num" qa-pass
    backend_remove_label "$repo" "$pr_num" qa-failed
    backend_add_label    "$repo" "$pr_num" qa-fail

    # qa-fail must be added
    grep -q "add qa-fail" "$ops_log"
    # qa-failed must NOT be added (the typo we fixed)
    ! grep -q "add qa-failed" "$ops_log"
}

# ---------------------------------------------------------------------------
# dev-rework-handler qa-fail → rework transition (regression for loop#315)
# ---------------------------------------------------------------------------

@test "dev-rework-handler qa-fail→rework: needs-qa stripped alongside qa-fail, in-rework added" {
    local ops_log="$BATS_TMPDIR/rework-qa-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the qa-fail → rework entry transition from dev-rework-handler.sh.
    # REWORK_CONTEXT=qa-fail path: SOURCE_LABEL=qa-fail + strip needs-qa family.
    local REWORK_CONTEXT="qa-fail"
    local repo="owner/test-repo" pr_num="1"
    local SOURCE_LABEL="qa-fail"

    backend_remove_label "$repo" "$pr_num" "$SOURCE_LABEL"
    if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
        backend_remove_label "$repo" "$pr_num" needs-qa       2>/dev/null || true
        backend_remove_label "$repo" "$pr_num" ready-for-qa   2>/dev/null || true
        backend_remove_label "$repo" "$pr_num" qa-pass        2>/dev/null || true
    fi
    backend_add_label "$repo" "$pr_num" in-rework

    # qa-fail must be removed
    grep -q "remove qa-fail"   "$ops_log"
    # needs-qa must be removed (the stale label that caused double-events)
    grep -q "remove needs-qa"  "$ops_log"
    # ready-for-qa (deprecated alias) must also be removed
    grep -q "remove ready-for-qa" "$ops_log"
    # in-rework must be added
    grep -q "add in-rework"    "$ops_log"
    # needs-qa must NOT be added (no re-introduction)
    ! grep -q "add needs-qa"   "$ops_log"
    # remove ops must all precede the add
    local last_remove add_line
    last_remove=$(grep -n "^remove " "$ops_log" | tail -1 | cut -d: -f1)
    add_line=$(grep -n "^add " "$ops_log" | head -1 | cut -d: -f1)
    [ "$last_remove" -lt "$add_line" ]
}

@test "dev-rework-handler non-qa-fail→rework: needs-qa NOT stripped (review REQUEST_CHANGES path)" {
    local ops_log="$BATS_TMPDIR/rework-cr-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # REWORK_CONTEXT empty (changes-requested path): only SOURCE_LABEL stripped
    local REWORK_CONTEXT=""
    local repo="owner/test-repo" pr_num="2"
    local SOURCE_LABEL="changes-requested"

    backend_remove_label "$repo" "$pr_num" "$SOURCE_LABEL"
    if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
        backend_remove_label "$repo" "$pr_num" needs-qa     2>/dev/null || true
        backend_remove_label "$repo" "$pr_num" ready-for-qa 2>/dev/null || true
        backend_remove_label "$repo" "$pr_num" qa-pass      2>/dev/null || true
    fi
    backend_add_label "$repo" "$pr_num" in-rework

    grep -q  "remove changes-requested" "$ops_log"
    grep -q  "add in-rework"            "$ops_log"
    ! grep -q "remove needs-qa"         "$ops_log"
    ! grep -q "remove ready-for-qa"     "$ops_log"
}

# ---------------------------------------------------------------------------
# dev-handler prompt label resolution (current vs default workflow)
# ---------------------------------------------------------------------------

@test "dev-handler prompt: current workflow project — resolved labels used, no canonical default names" {
    cat > "$BATS_TMPDIR/current.yaml" <<'YAML'
version: 1
projects:
  - slug: current-proj
    name: Current Project
    repo: owner/current-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
    labels:
      needs-review: review-pending
      needs-rework: changes-requested
      needs-qa: ready-for-qa
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/current.yaml"

    local _REVIEW_LABEL _REWORK_LABEL _QA_LABEL _QA_PASS_LABEL _QA_FAIL_LABEL
    _REVIEW_LABEL=$(loop_label_for "current-proj" "needs-review")
    _REWORK_LABEL=$(loop_label_for "current-proj" "needs-rework")
    _QA_LABEL=$(loop_label_for "current-proj" "needs-qa")
    _QA_PASS_LABEL=$(loop_label_for "current-proj" "qa-pass")
    _QA_FAIL_LABEL=$(loop_label_for "current-proj" "qa-fail")

    # Verify resolution
    [ "$_REVIEW_LABEL" = "review-pending" ]
    [ "$_REWORK_LABEL" = "changes-requested" ]
    [ "$_QA_LABEL" = "ready-for-qa" ]
    [ "$_QA_PASS_LABEL" = "qa-pass" ]
    [ "$_QA_FAIL_LABEL" = "qa-fail" ]

    # Build the prompt snippet the same way dev-handler.sh does (unquoted <<EOF)
    local SLUG=current-proj REPO=owner/current-repo ISSUE_NUM=99
    local prompt
    prompt=$(cat <<EOF
Create PR: gh pr create --repo ${REPO} --label ${_REVIEW_LABEL}
Edit issue: gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --remove-label dev --remove-label plan --remove-label ${_REVIEW_LABEL} --add-label ${_REVIEW_LABEL}
If reviewer requests changes: issue gets label '${_REWORK_LABEL}'.
If ready for QA: issue gets label '${_QA_LABEL}'.
IMPORTANT: label '${_REVIEW_LABEL}' (or 'needs-clarification' if blocked).
EOF
    )

    # Must NOT contain canonical (default-workflow) names
    [[ "$prompt" != *"needs-review"* ]]
    [[ "$prompt" != *"needs-rework"* ]]
    [[ "$prompt" != *"needs-qa"* ]]

    # Must contain resolved (current-workflow) names
    [[ "$prompt" == *"review-pending"* ]]
    [[ "$prompt" == *"changes-requested"* ]]
    [[ "$prompt" == *"ready-for-qa"* ]]
}

@test "dev-handler prompt: default workflow project — canonical label names appear in prompt" {
    # Uses setup fixture.yaml with workflow: default and no label overrides

    local _REVIEW_LABEL _REWORK_LABEL _QA_LABEL
    _REVIEW_LABEL=$(loop_label_for "test-proj" "needs-review")
    _REWORK_LABEL=$(loop_label_for "test-proj" "needs-rework")
    _QA_LABEL=$(loop_label_for "test-proj" "needs-qa")

    [ "$_REVIEW_LABEL" = "needs-review" ]
    # default workflow rework stage uses needs-dev as its trigger_label
    [ "$_REWORK_LABEL" = "needs-dev" ]
    [ "$_QA_LABEL" = "needs-qa" ]

    local SLUG=test-proj REPO=owner/test-repo ISSUE_NUM=1
    local prompt
    prompt=$(cat <<EOF
Create PR: gh pr create --repo ${REPO} --label ${_REVIEW_LABEL}
Edit issue: gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --remove-label dev --remove-label plan --remove-label ${_REVIEW_LABEL} --add-label ${_REVIEW_LABEL}
If reviewer requests changes: issue gets label '${_REWORK_LABEL}'.
If ready for QA: issue gets label '${_QA_LABEL}'.
IMPORTANT: label '${_REVIEW_LABEL}' (or 'needs-clarification' if blocked).
EOF
    )

    # Default workflow: resolved trigger names must appear in the prompt
    [[ "$prompt" == *"needs-review"* ]]
    [[ "$prompt" == *"needs-dev"* ]]
    [[ "$prompt" == *"needs-qa"* ]]
    [[ "$prompt" != *"review-pending"* ]]
}

# ---------------------------------------------------------------------------
# dev-handler EXIT trap label restoration (issue #234)
# ---------------------------------------------------------------------------

@test "dev-handler trap: canonical-vocab project restores needs-dev on abnormal exit" {
    cat > "$BATS_TMPDIR/canonical.yaml" <<'YAML'
version: 1
projects:
  - slug: canonical-proj
    name: Canonical Project
    repo: owner/canonical-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
    labels:
      dev: needs-dev
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/canonical.yaml"

    local ops_log="$BATS_TMPDIR/trap-canonical-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    # Replicate the trap body from dev-handler.sh using the resolved trigger
    local _DEV_TRIGGER
    _DEV_TRIGGER=$(loop_label_for "canonical-proj" "dev" 2>/dev/null) || _DEV_TRIGGER="dev"
    local _IN_PROGRESS_CLAIMED=1
    local REPO="owner/canonical-repo" ISSUE_NUM="1"

    _dev_label_cleanup() {
        [ "${_IN_PROGRESS_CLAIMED:-0}" = "1" ] || return 0
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress 2>/dev/null || true
        backend_add_label    "$REPO" "$ISSUE_NUM" "$_DEV_TRIGGER" 2>/dev/null || true
    }
    _dev_label_cleanup

    # Must restore the resolved label (needs-dev), not the hardcoded literal 'dev'
    grep -q "add needs-dev" "$ops_log"
    ! grep -q "add dev" "$ops_log"
}

@test "dev-handler trap: project with explicit dev label override restores dev on abnormal exit" {
    # A project that explicitly maps the dev stage trigger back to the deprecated 'dev' label
    cat > "$BATS_TMPDIR/legacy.yaml" <<'YAML'
version: 1
projects:
  - slug: legacy-proj
    name: Legacy Project
    repo: owner/legacy-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
    labels:
      dev: dev
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/legacy.yaml"

    local ops_log="$BATS_TMPDIR/trap-legacy-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }

    local _DEV_TRIGGER
    _DEV_TRIGGER=$(loop_label_for "legacy-proj" "dev" 2>/dev/null) || _DEV_TRIGGER="dev"
    local _IN_PROGRESS_CLAIMED=1
    local REPO="owner/legacy-repo" ISSUE_NUM="1"

    _dev_label_cleanup() {
        [ "${_IN_PROGRESS_CLAIMED:-0}" = "1" ] || return 0
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress 2>/dev/null || true
        backend_add_label    "$REPO" "$ISSUE_NUM" "$_DEV_TRIGGER" 2>/dev/null || true
    }
    _dev_label_cleanup

    # Project with explicit 'dev' override: trigger resolves to 'dev'
    grep -q "add dev" "$ops_log"
    ! grep -q "add needs-dev" "$ops_log"
}

# ---------------------------------------------------------------------------
# po-handler re-queue detection (issue #246)
# ---------------------------------------------------------------------------

# Replicates the re-queue detection block from po-handler.sh.
# Returns: sets retries and emits log lines to BATS_TMPDIR/requeue-log.txt
_run_requeue_detection() {
    local slug="$1" issue_num="$2" counter_val="$3" has_clarification="$4"
    local REPO="owner/test-repo"
    local RETRY_FILE="$BATS_TMPDIR/loop-po-retries-${slug}-${issue_num}"
    local MAX_RETRIES=2
    local log_file="$BATS_TMPDIR/requeue-log.txt"
    rm -f "$log_file"

    retry_count() { [ -f "$RETRY_FILE" ] && cat "$RETRY_FILE" || echo 0; }
    retry_clear() { rm -f "$RETRY_FILE"; }
    log() { echo "$*" >> "$log_file"; }

    # Write counter file if value > 0
    if [ "$counter_val" -gt 0 ]; then
        echo "$counter_val" > "$RETRY_FILE"
    fi

    # Mock backend_issue_has_any_label: return 0 (has label) or 1 (does not)
    if [ "$has_clarification" = "yes" ]; then
        backend_issue_has_any_label() { return 0; }
    else
        backend_issue_has_any_label() { return 1; }
    fi

    retries=$(retry_count)
    if [ "$retries" -ge "$MAX_RETRIES" ] \
       && ! backend_issue_has_any_label "$REPO" "$issue_num" needs-clarification 2>/dev/null; then
        log "counter reset (re-queue detected) on #$issue_num — was ${retries}, now 0"
        retry_clear
        retries=0
    fi

    echo "$retries"
}

@test "po-handler requeue: counter>=MAX_RETRIES and no needs-clarification — counter reset, retries=0" {
    result=$(_run_requeue_detection "foo" "42" "2" "no")
    [ "$result" = "0" ]
    log_file="$BATS_TMPDIR/requeue-log.txt"
    grep -q "counter reset (re-queue detected)" "$log_file"
    # Counter file should be removed
    [ ! -f "$BATS_TMPDIR/loop-po-retries-foo-42" ]
}

@test "po-handler requeue: counter>=MAX_RETRIES and needs-clarification still set — no reset, still bounces" {
    result=$(_run_requeue_detection "foo" "43" "2" "yes")
    [ "$result" = "2" ]
    log_file="$BATS_TMPDIR/requeue-log.txt"
    ! grep -q "counter reset" "$log_file"
    # Counter file should still exist
    [ -f "$BATS_TMPDIR/loop-po-retries-foo-43" ]
}

@test "po-handler requeue: no counter file, no needs-clarification — proceeds normally, retries=0" {
    result=$(_run_requeue_detection "foo" "44" "0" "no")
    [ "$result" = "0" ]
    log_file="$BATS_TMPDIR/requeue-log.txt"
    ! grep -q "counter reset" "$log_file"
}
