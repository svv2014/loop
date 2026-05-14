#!/usr/bin/env bats
# tests/qa-handler-external-pr-gate.bats
# Regression tests for the safe-to-test gate in scripts/qa-handler.sh.
#
# The gate ensures that QA's validation_cmd (which executes arbitrary project
# code) never runs against an external-pr unless an operator has explicitly
# approved it with the safe-to-test label.

setup() {
    OPS_LOG="$BATS_TMPDIR/label-ops.log"
    COMMENT_LOG="$BATS_TMPDIR/comment.log"
    BOUNTY_LOG="$BATS_TMPDIR/bounty.log"
    AGENT_LOG="$BATS_TMPDIR/agent.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$BOUNTY_LOG" "$AGENT_LOG"

    export REPO="owner/test-repo"
    export PR_NUM="42"
    export SLUG="test-proj"
    export LOOP_AGENT_MODEL="sonnet"
    export LOOP_LABEL_NEEDS_QA="needs-qa"
    export LOOP_LABEL_DEPRECATED_READY_FOR_QA="ready-for-qa"
}

teardown() {
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$BOUNTY_LOG" "$AGENT_LOG"
}

# ---------------------------------------------------------------------------
# Helper: replicate the gate block from scripts/qa-handler.sh in isolation so
# we can exercise it without booting the full handler (which needs project
# config, locks, runner, etc.).
# ---------------------------------------------------------------------------
_run_gate() {
    local labels_csv="$1"
    # Build labels JSON from CSV
    local labels_json
    labels_json=$(python3 -c "
import json, sys
items = [s for s in '''$labels_csv'''.split(',') if s.strip()]
print(json.dumps({'labels': [{'name': s.strip()} for s in items]}))
")

    backend_pr_view() { printf '%s' "$labels_json"; }
    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_comment_pr()   { echo "comment: $3" >> "$COMMENT_LOG"; }
    bounty_report() { echo "bounty $1: $*" >> "$BOUNTY_LOG"; }
    loop_canonical_label() { echo "$1"; }
    log() { true; }
    loop_run_agent() { echo "agent-invoked" >> "$AGENT_LOG"; return 0; }

    # --- The gate (mirrors scripts/qa-handler.sh) ---
    local _PR_LABELS_JSON _PR_LABELS _has_external_pr=0 _has_safe_to_test=0
    _PR_LABELS_JSON=$(backend_pr_view "$REPO" "$PR_NUM" --json labels 2>/dev/null || echo '{"labels":[]}')
    _PR_LABELS=$(echo "$_PR_LABELS_JSON" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(''); sys.exit(0)
for l in d.get('labels', []):
    name = l.get('name','') if isinstance(l, dict) else str(l)
    if name:
        print(name)" 2>/dev/null || echo "")

    while IFS= read -r _lbl; do
        [ -z "$_lbl" ] && continue
        case "$_lbl" in
            external-pr) _has_external_pr=1 ;;
            safe-to-test) _has_safe_to_test=1 ;;
        esac
    done <<< "$_PR_LABELS"

    if [ "$_has_external_pr" = "1" ] && [ "$_has_safe_to_test" != "1" ]; then
        bounty_report "qa_skipped" model="sonnet" role=qa project="$SLUG" pr_num="$PR_NUM" \
            detail="external-pr without safe-to-test — operator must approve"
        backend_comment_pr "$REPO" "$PR_NUM" \
            "QA blocked: this PR is labeled \`external-pr\` but not \`safe-to-test\`. An operator must apply the \`safe-to-test\` label to permit QA execution."
        backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_NEEDS_QA"
        backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_READY_FOR_QA"
        return 0
    fi

    # Otherwise: proceed to "agent dispatch" (mocked).
    loop_run_agent "prompt" "/tmp"
    return 0
}

# ---------------------------------------------------------------------------
# Case 1: external-pr + safe-to-test → gate passes, agent dispatched
# ---------------------------------------------------------------------------

@test "external-pr + safe-to-test: gate proceeds (agent invoked)" {
    _run_gate "external-pr,safe-to-test,needs-qa"
    [ -f "$AGENT_LOG" ]
    grep -q "agent-invoked" "$AGENT_LOG"
}

@test "external-pr + safe-to-test: no qa_skipped bounty" {
    _run_gate "external-pr,safe-to-test,needs-qa"
    [ ! -f "$BOUNTY_LOG" ] || ! grep -q "qa_skipped" "$BOUNTY_LOG"
}

@test "external-pr + safe-to-test: no QA-blocked comment" {
    _run_gate "external-pr,safe-to-test,needs-qa"
    [ ! -f "$COMMENT_LOG" ] || ! grep -q "QA blocked" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Case 2: external-pr WITHOUT safe-to-test → gate trips, exit 0
# ---------------------------------------------------------------------------

@test "external-pr without safe-to-test: emits qa_skipped" {
    _run_gate "external-pr,needs-qa"
    grep -q "qa_skipped" "$BOUNTY_LOG"
}

@test "external-pr without safe-to-test: posts QA-blocked comment" {
    _run_gate "external-pr,needs-qa"
    grep -q "QA blocked" "$COMMENT_LOG"
    grep -q "safe-to-test" "$COMMENT_LOG"
}

@test "external-pr without safe-to-test: removes needs-qa and ready-for-qa" {
    _run_gate "external-pr,needs-qa"
    grep -q "remove needs-qa" "$OPS_LOG"
    grep -q "remove ready-for-qa" "$OPS_LOG"
}

@test "external-pr without safe-to-test: agent NOT invoked" {
    _run_gate "external-pr,needs-qa"
    [ ! -f "$AGENT_LOG" ] || ! grep -q "agent-invoked" "$AGENT_LOG"
}

@test "external-pr without safe-to-test: clean exit (status 0)" {
    run _run_gate "external-pr,needs-qa"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Case 3: No external-pr label → gate is transparent, agent dispatched
# ---------------------------------------------------------------------------

@test "no external-pr label: gate proceeds (agent invoked)" {
    _run_gate "needs-qa"
    [ -f "$AGENT_LOG" ]
    grep -q "agent-invoked" "$AGENT_LOG"
}

@test "no external-pr label: no qa_skipped bounty" {
    _run_gate "needs-qa"
    [ ! -f "$BOUNTY_LOG" ] || ! grep -q "qa_skipped" "$BOUNTY_LOG"
}

@test "no external-pr label: no comment posted" {
    _run_gate "needs-qa"
    [ ! -f "$COMMENT_LOG" ] || ! grep -q "QA blocked" "$COMMENT_LOG"
}
