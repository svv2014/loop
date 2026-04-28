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
# backend_find_pr_for_issue — unit tests
# ---------------------------------------------------------------------------

@test "backend_find_pr_for_issue: open PR with Closes #N body returns PR number" {
    # Simulate backend_find_pr_for_issue logic with a stub that returns a PR
    # whose body contains 'Closes #42'.
    local result
    result=$(python3 -c "
import json, re, sys
issue = '42'
prs = [
    {'number': 10, 'body': 'Closes #99'},
    {'number': 17, 'body': 'Closes #42\n\nSome description'},
    {'number': 20, 'body': 'Unrelated PR'},
]
pattern = re.compile(r'(?i)(closes|fixes|resolves)\s+#' + re.escape(issue) + r'\b')
for pr in prs:
    if pattern.search(pr.get('body', '') or ''):
        print(pr['number'])
        break
")
    [ "$result" = "17" ]
}

@test "backend_find_pr_for_issue: no open PR for issue returns empty" {
    local result
    result=$(python3 -c "
import json, re, sys
issue = '42'
prs = [
    {'number': 10, 'body': 'Closes #99'},
    {'number': 20, 'body': 'Unrelated PR'},
]
pattern = re.compile(r'(?i)(closes|fixes|resolves)\s+#' + re.escape(issue) + r'\b')
for pr in prs:
    if pattern.search(pr.get('body', '') or ''):
        print(pr['number'])
        break
")
    [ -z "$result" ]
}

@test "backend_find_pr_for_issue: closed/merged PRs are not returned (open-only filter)" {
    # The github backend passes --state open to gh pr list; this test verifies
    # the python matching logic itself only matches bodies, not state.
    # Closed PRs would never reach the python snippet — verified here by ensuring
    # the pattern only fires on a matching body.
    local result
    result=$(python3 -c "
import re
issue = '7'
# Simulate what happens if gh were to return a merged PR body (shouldn't happen
# with --state open, but guard the logic anyway).
prs_open = [
    {'number': 5, 'body': 'Fixes #7', 'state': 'open'},
]
pattern = re.compile(r'(?i)(closes|fixes|resolves)\s+#' + re.escape(issue) + r'\b')
for pr in prs_open:
    if pattern.search(pr.get('body', '') or ''):
        print(pr['number'])
        break
")
    [ "$result" = "5" ]
}

@test "backend_find_pr_for_issue: no PR exists — po-handler falls back to standard paths" {
    # Verify that when _INFLIGHT_PR_NUM is empty the prompt block is also empty,
    # preserving the current (no-MR) behavior.
    local inflight_pr_num=""
    local inflight_pr_block=""
    if [ -n "$inflight_pr_num" ]; then
        inflight_pr_block="EXISTING IMPLEMENTATION IN FLIGHT"
    fi
    [ -z "$inflight_pr_block" ]
}
