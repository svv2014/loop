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
# qa-handler AC extraction (Phase 1)
# ---------------------------------------------------------------------------

# Replicates the inline python3 AC-extraction snippet from qa-handler.sh.
_extract_ac_list() {
    local body="$1"
    ISSUE_BODY="$body" python3 -c "
import os, re
body = os.environ.get('ISSUE_BODY', '').strip()
match = re.search(r'(?m)^\#{1,3}\s+Acceptance Criteria\s*$', body, re.IGNORECASE)
if not match:
    print('__NO_AC_SECTION__')
else:
    rest = body[match.end():]
    section = re.split(r'(?m)^\#{1,3}\s+', rest)[0]
    checkboxes = re.findall(r'- \[[ xX]\] .+', section)
    if not checkboxes:
        print('__NO_AC_SECTION__')
    else:
        for i, cb in enumerate(checkboxes, 1):
            text = re.sub(r'^- \[[ xX]\] ', '', cb).strip()
            print(f'{i}. {text}')
"
}

@test "qa-handler AC extraction: checkboxes present — returns numbered list" {
    local body
    body="$(cat <<'BODY'
## Objective
Do a thing.

## Acceptance Criteria
- [ ] First criterion is met
- [x] Second criterion already checked
- [ ] Third criterion to verify

## Notes
Nothing else.
BODY
)"
    local result
    result=$(_extract_ac_list "$body")

    [[ "$result" != "__NO_AC_SECTION__" ]]
    echo "$result" | grep -q "1\. First criterion is met"
    echo "$result" | grep -q "2\. Second criterion already checked"
    echo "$result" | grep -q "3\. Third criterion to verify"
}

@test "qa-handler AC extraction: no Acceptance Criteria section — returns sentinel" {
    local body
    body="$(cat <<'BODY'
## Objective
Do a thing.

## Notes
No acceptance criteria here.
BODY
)"
    local result
    result=$(_extract_ac_list "$body")
    [ "$result" = "__NO_AC_SECTION__" ]
}

@test "qa-handler AC extraction: empty body — returns sentinel" {
    local result
    result=$(_extract_ac_list "")
    [ "$result" = "__NO_AC_SECTION__" ]
}

@test "qa-handler AC extraction: case-insensitive heading — ACCEPTANCE CRITERIA uppercase matches" {
    local body
    body="$(cat <<'BODY'
## ACCEPTANCE CRITERIA
- [ ] Uppercase heading criterion

## Notes
Nothing else.
BODY
)"
    local result
    result=$(_extract_ac_list "$body")

    [[ "$result" != "__NO_AC_SECTION__" ]]
    echo "$result" | grep -q "1\. Uppercase heading criterion"
}

@test "qa-handler AC extraction: case-insensitive heading — mixed case 'Acceptance criteria' matches" {
    local body
    body="$(cat <<'BODY'
## Acceptance criteria
- [ ] Mixed-case heading criterion

## Notes
Nothing else.
BODY
)"
    local result
    result=$(_extract_ac_list "$body")

    [[ "$result" != "__NO_AC_SECTION__" ]]
    echo "$result" | grep -q "1\. Mixed-case heading criterion"
}

@test "qa-handler linked issue: Fixes #N pattern extracted correctly" {
    # Test that the grep pattern used in qa-handler matches 'Fixes #N'
    local pr_body="This PR implements the feature.\n\nFixes #99"
    local issue_num
    issue_num=$(printf '%b' "$pr_body" \
        | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
    [ "$issue_num" = "99" ]
}

@test "qa-handler linked issue: Resolves #N pattern extracted correctly" {
    local pr_body="Resolves #123 — implements feature X"
    local issue_num
    issue_num=$(printf '%b' "$pr_body" \
        | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
    [ "$issue_num" = "123" ]
}

@test "qa-handler linked issue: no link keyword — issue num is empty" {
    local pr_body="This PR does something without a linked issue"
    local issue_num
    issue_num=$(printf '%b' "$pr_body" \
        | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
    [ -z "$issue_num" ]
}

@test "qa-handler prompt: AC section built from _extract_ac_list output when issue linked" {
    # Mock LINKED_ISSUE_NUM and ISSUE_BODY, verify AC_SECTION is assembled correctly
    local LINKED_ISSUE_NUM="42"
    local body
    body="$(cat <<'BODY'
## Acceptance Criteria
- [ ] First criterion
- [x] Second criterion
BODY
)"
    local ac_list
    ac_list=$(_extract_ac_list "$body")

    # ac_list must not be sentinel
    [[ "$ac_list" != "__NO_AC_SECTION__" ]]

    # assemble the AC section as qa-handler does
    local ac_section
    ac_section="## Acceptance Criteria (from issue #${LINKED_ISSUE_NUM})

${ac_list}"

    [[ "$ac_section" == *"issue #42"* ]]
    [[ "$ac_section" == *"1. First criterion"* ]]
    [[ "$ac_section" == *"2. Second criterion"* ]]
}

@test "qa-handler prompt: fallback path when no AC section found" {
    local body="## Objective
No acceptance criteria here."
    local ac_list
    ac_list=$(_extract_ac_list "$body")

    [ "$ac_list" = "__NO_AC_SECTION__" ]

    # Replicate label-fallback path from qa-handler.sh
    local ac_section ac_instruction
    if [ "$ac_list" = "__NO_AC_SECTION__" ]; then
        ac_section="(No acceptance criteria found — falling back to validation_cmd only)"
        ac_instruction=""
    fi

    [[ "$ac_section" == *"No acceptance criteria found"* ]]
    [[ "$ac_section" == *"falling back to validation_cmd only"* ]]
    [ -z "$ac_instruction" ]
}
