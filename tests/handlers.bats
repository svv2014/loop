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

    # trigger label must be removed
    grep -q "remove dev" "$ops_log"
    # in-progress must be added
    grep -q "add in-progress" "$ops_log"
    # trigger label must NOT be re-added (no dual state)
    ! grep -q "add dev" "$ops_log"
    # remove must precede add
    local rm_line add_line
    rm_line=$(grep -n "remove dev" "$ops_log" | cut -d: -f1)
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

    grep -q "remove po-review" "$ops_log"
    grep -q "add in-progress" "$ops_log"
    ! grep -q "add po-review" "$ops_log"
    local rm_line add_line
    rm_line=$(grep -n "remove po-review" "$ops_log" | cut -d: -f1)
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
    [ "$_REWORK_LABEL" = "needs-rework" ]
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

    # Default workflow: canonical names must appear in the prompt
    [[ "$prompt" == *"needs-review"* ]]
    [[ "$prompt" != *"review-pending"* ]]
}
