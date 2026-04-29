#!/usr/bin/env bash
# qa-handler.sh — handles one loop.pr_qa event.
# Deprecated name: prefer scripts/tester.sh
#
# Event payload: {"slug","repo","pr_number","pr_title","pr_url"}
#
# Flow: invoke smart four-phase QA agent that verifies acceptance criteria,
# creates targeted tests, runs regression on touched modules, then runs
# validation_cmd. Agent posts structured comment and applies qa-pass/qa-failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/runner.sh
source "$LOOP_ROOT/lib/runner.sh"
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/cli-hint.sh
source "$LOOP_ROOT/lib/cli-hint.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-qa-handler.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [qa-handler] $*" | tee -a "$LOG_FILE"; }

# Read event fields — prefer discrete env vars (set by router), fall back to JSON.
SLUG="${LOOP_SLUG:-}"
PR_NUM="${LOOP_PR_NUMBER:-}"

if [ -z "$SLUG" ] || [ -z "$PR_NUM" ]; then
    EVENT_JSON="${LOOP_EVENT_JSON:-}"
    if [ -z "$EVENT_JSON" ] && [ ! -t 0 ]; then
        EVENT_JSON=$(cat)
    fi
    if [ -n "$EVENT_JSON" ]; then
        SLUG=$(echo "$EVENT_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('slug',''))")
        PR_NUM=$(echo "$EVENT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_number',''))")
    fi
fi

[ -n "$SLUG" ] && [ -n "$PR_NUM" ] \
    || { log "ERROR: missing slug or pr_number"; exit 2; }

loop_load_project "$SLUG" || { log "ERROR: unknown slug '$SLUG'"; exit 2; }
loop_load_backend

# Resolve workflow-specific labels for this project.
_QA_PASS_LABEL=$(loop_label_for "$SLUG" "qa-pass")
_QA_FAIL_LABEL=$(loop_label_for "$SLUG" "qa-fail")

# Per-project lock — only one Loop handler at a time per repo.
source "$LOOP_ROOT/lib/lock.sh"
loop_acquire_lock "$SLUG" || { log "ERROR: couldn't acquire lock for $SLUG within 1hr — exiting"; exit 1; }
log "acquired project lock for $SLUG"

log "qa: slug=$SLUG repo=$REPO pr=#$PR_NUM"
bounty_report "qa_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true

# Pre-flight: skip if PR is already merged or closed — avoids running validation against stale state.
PR_STATE=$(backend_pr_view "$REPO" "$PR_NUM" --json state --jq .state 2>/dev/null || echo "")
case "$PR_STATE" in
    MERGED|CLOSED)
        log "PR #$PR_NUM is already $PR_STATE — skipping QA, removing needs-qa"
        backend_remove_label "$REPO" "$PR_NUM" needs-qa
        backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
        exit 0
        ;;
esac

# Auto-promote drafts — PRs are no longer opened as drafts, but promote any legacy ones.
_is_draft=$(gh pr view "$PR_NUM" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")
if [ "$_is_draft" = "true" ]; then
    log "PR #$PR_NUM is a draft — auto-promoting to ready"
    gh pr ready "$PR_NUM" --repo "$REPO" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" draft 2>/dev/null || true
fi

loop_notify "▶️ [$SLUG] PR#$PR_NUM qa starting"

_BACKEND_CLI_NOTE=$(backend_cli_note)
_VALIDATION_CMD="${QA_VALIDATION_CMD:-}"

_PROMPT_FILE=$(mktemp /tmp/qa-prompt-XXXXXX.txt)
cat > "$_PROMPT_FILE" <<EOF
You are the Senior QA Verifier for ${NAME} (slug: ${SLUG}).
Project root: ${ROOT}
Repo: ${REPO}

READ ${ROOT}/CLAUDE.md first for project conventions.
If CLAUDE.md is missing, note its absence and proceed with best-practice conventions.

You are performing four-phase smart QA on pull request #${PR_NUM}.

## Setup

1. Check PR state:
   gh pr view ${PR_NUM} --repo ${REPO} --json state,merged
   If state=MERGED or state=CLOSED: remove labels 'ready-for-qa' and 'needs-qa',
   leave a comment "PR already closed/merged — QA skipped.", and stop.

2. Fetch PR details and diff:
   gh pr view ${PR_NUM} --repo ${REPO} --json title,body,headRefName,files,closingIssuesReferences
   gh pr diff ${PR_NUM} --repo ${REPO}

3. Identify the linked issue (from closingIssuesReferences). Fetch its body:
   gh issue view <N> --repo ${REPO} --json body

4. Check if the issue body contains a "## Acceptance Criteria" section with "- [ ]" checkboxes.
   If it does NOT contain "## Acceptance Criteria": skip Phases 1 and 2, run Phases 3 and 4 only,
   and note the gap in your PR comment (the issue lacked acceptance criteria).

---

## Phase 1 — Verify each acceptance criterion

Parse the "## Acceptance Criteria" checkboxes from the linked issue body.
For each criterion output one of:
- VERIFIED — explain how the diff satisfies it; where possible, prove with a one-line command and quote actual output.
- NOT_FOUND — the diff does not address this criterion; quote what is missing.
- PARTIAL — partially addressed; explain what is done and what is missing.

If any criterion is NOT_FOUND or PARTIAL → verdict is qa-fail (list each unmet AC).

---

## Phase 2 — Create tests where they earn their keep

Per-criterion decision: only create a test when the behavior is mechanical (input → output) or
non-obvious AND the project already has a testing framework (bats / pytest / vitest).
Write tests in the existing framework, place next to existing tests, run them, and if they pass,
commit and push to the PR branch:

   cd ${ROOT}
   git fetch origin
   git checkout <headRefName>
   # write test file
   git add <test-file>
   git commit -m 'test: add QA-driven tests for PR #${PR_NUM}'
   git push --force-with-lease origin <headRefName>

Skip test creation for: UI-only changes, doc updates, cases with existing integration coverage,
or trivially obvious diff hunks. Note the rationale for each skip.

If newly added tests fail → verdict is qa-fail (cite the contradiction).

---

## Phase 3 — Targeted regression on touched modules

List the files this PR touched (from the "files" field of gh pr view).
For each touched file, find covering test files by convention:
- tests/<module>.bats (strip path prefix and .sh extension)
- test_*.py near the file
- *.test.js / *.spec.js near the file

Run only those covering tests (e.g. bats tests/foo.bats).
A test failure = regression caused by this PR → verdict is qa-fail (cite the specific failing test).
If no test coverage exists for a touched file, note it and skip.

---

## Phase 4 — Final regression guard

Run the validation command:
$([ -n "$_VALIDATION_CMD" ] && printf '   cd %s && %s' "${ROOT}" "$_VALIDATION_CMD" || printf '   (no validation_cmd configured for this project — Phase 4 skipped)')

If validation_cmd fails → verdict is qa-fail (cite the validation failure output).

---

## Decision and labeling

After all phases, post a structured comment on the PR using this template:

\`\`\`
### QA verification — issue #<N>

**Phase 1: Acceptance criteria**
1. [✓ VERIFIED] <AC text>
   _Proof:_ \`<command>\` → \`<output snippet>\`
2. [✗ NOT_FOUND] <AC text>
   Diff does not address this. Need: <what>.

**Phase 2: Tests added**
- \`tests/foo.bats::handles_empty_input\` (covers AC2)
- (skipped AC1: doc-only change)

**Phase 3: Regression on touched modules**
- \`lib/foo.sh\` → ran \`tests/foo.bats\` (12 tests, ✓ pass)
- \`lib/bar.sh\` → no existing test coverage, skipped

**Phase 4: validation_cmd**
- \`<cmd>\` → ✓ pass

**Verdict:** <qa-pass or qa-fail — reason>
\`\`\`

Post the comment:
   gh pr comment ${PR_NUM} --repo ${REPO} --body '<comment text>'

Then apply the label:

If qa-pass:
   gh pr edit ${PR_NUM} --repo ${REPO} --remove-label needs-qa --remove-label ready-for-qa --remove-label qa-failed --remove-label qa-fail --add-label ${_QA_PASS_LABEL}

If qa-fail:
   gh pr edit ${PR_NUM} --repo ${REPO} --remove-label needs-qa --remove-label ready-for-qa --remove-label approved --remove-label qa-pass --remove-label qa-fail --add-label ${_QA_FAIL_LABEL}

IMPORTANT: You MUST finish by applying either '${_QA_PASS_LABEL}' or '${_QA_FAIL_LABEL}'. The pipeline
stalls if neither is applied. Verify with:
   gh pr view ${PR_NUM} --repo ${REPO} --json labels

${_BACKEND_CLI_NOTE}
$(loop_cli_hint)
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

if loop_run_agent "$TASK_PROMPT" "$ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    log "qa agent finished for PR #$PR_NUM"
    loop_notify "✅ [$SLUG] PR#$PR_NUM qa done"
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa

    # Report the actual outcome based on which label the agent applied.
    if backend_pr_has_any_label "$REPO" "$PR_NUM" qa-pass "$_QA_PASS_LABEL"; then
        bounty_report "qa_pass" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    else
        bounty_report "qa_fail" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    fi

    # Belt-and-braces: if agent forgot to apply a decision label, default to qa-failed.
    if ! backend_pr_has_any_label "$REPO" "$PR_NUM" qa-pass qa-failed "$_QA_PASS_LABEL" "$_QA_FAIL_LABEL"; then
        log "WARN: PR #$PR_NUM has no QA decision label after agent — defaulting to ${_QA_FAIL_LABEL}"
        backend_remove_label "$REPO" "$PR_NUM" qa-pass
        backend_add_label "$REPO" "$PR_NUM" "$_QA_FAIL_LABEL"
        backend_comment_pr "$REPO" "$PR_NUM" \
            "QA agent ran but did not apply a decision label. Defaulting to ${_QA_FAIL_LABEL}. Operator: see ${LOG_FILE} for the agent transcript." \
            2>/dev/null || true
        bounty_report "qa_fail" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    fi
else
    log "qa agent failed for PR #$PR_NUM"
    bounty_report "qa_fail" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "❌ [$SLUG] PR#$PR_NUM qa failed: agent error"
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_remove_label "$REPO" "$PR_NUM" approved
    backend_remove_label "$REPO" "$PR_NUM" qa-pass
    backend_remove_label "$REPO" "$PR_NUM" qa-fail
    backend_add_label "$REPO" "$PR_NUM" "$_QA_FAIL_LABEL"
    backend_comment_pr "$REPO" "$PR_NUM" \
        "QA agent failed. Operator: see ${LOG_FILE} for the agent transcript." \
        2>/dev/null || true
    exit 1
fi
