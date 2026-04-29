#!/usr/bin/env bash
# qa-handler.sh — handles one loop.pr_qa event.
# Deprecated name: prefer scripts/tester.sh
#
# Event payload: {"slug","repo","pr_number","pr_title","pr_url"}
#
# Phase 1 (smart QA): extracts ## Acceptance Criteria checkboxes from the linked
# issue and injects them into the agent prompt so the agent can verify each
# criterion against the PR diff.  Falls back to validation_cmd-only when no
# AC section is found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/runner.sh
source "$LOOP_ROOT/lib/runner.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/cli-hint.sh
source "$LOOP_ROOT/lib/cli-hint.sh"

# ── structured-comment helpers ────────────────────────────────────────────

# Print the first Closes/Fixes/Resolves #N issue number from PR body, or empty string.
_qa_linked_issue() {
    local pr_body="$1"
    printf '%s' "$pr_body" | python3 -c "
import sys, re
m = re.search(r'(?i)(closes|fixes|resolves)\s+#(\d+)', sys.stdin.read())
print(m.group(2) if m else '')
"
}

# Print 'yes' if issue body has a ## Acceptance Criteria section.
_qa_has_ac() {
    local body="$1"
    printf '%s' "$body" | python3 -c "
import sys, re
print('yes' if re.search(r'^##\s+Acceptance Criteria', sys.stdin.read(), re.MULTILINE | re.IGNORECASE) else 'no')
"
}

# Print numbered AC items extracted from ## Acceptance Criteria section.
_qa_parse_acs() {
    local body="$1"
    printf '%s' "$body" | python3 -c "
import sys, re
body = sys.stdin.read()
m = re.search(r'^##\s+Acceptance Criteria\s*\n(.*?)(?=\n##\s|\Z)', body, re.DOTALL | re.MULTILINE | re.IGNORECASE)
if not m:
    sys.exit(0)
items = []
for line in m.group(1).splitlines():
    stripped = re.sub(r'^\s*-\s*\[[ xX]\]\s*', '', line)
    if stripped != line:
        items.append(stripped.strip())
for i, item in enumerate(items, 1):
    print(str(i) + '. ' + item)
"
}

# Build and print the structured QA PR comment.
# Args: issue_num verdict validation_cmd ac_list has_ac
_qa_build_comment() {
    local issue_num="$1" verdict="$2" validation_cmd="$3" ac_list="$4" has_ac="$5"

    local phase1_body
    if [ "$has_ac" = "no" ] || [ -z "$ac_list" ]; then
        phase1_body="No acceptance criteria found — validation_cmd only"
    else
        phase1_body=""
        local n=1
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            local ac_text="${item#*. }"
            phase1_body="${phase1_body}${n}. ${ac_text}
   _Based on validation_cmd result below._
"
            n=$((n + 1))
        done <<< "$ac_list"
    fi

    local phase4_body
    if [ -n "$validation_cmd" ]; then
        if [ "$verdict" = "qa-pass" ]; then
            phase4_body="- \`${validation_cmd}\` → [✓ pass]"
        else
            phase4_body="- \`${validation_cmd}\` → [✗ fail]"
        fi
    else
        phase4_body="- (no validation_cmd configured — Phase 4 skipped)"
    fi

    local verdict_line
    if [ "$verdict" = "qa-pass" ]; then
        verdict_line="qa-pass"
    else
        verdict_line="qa-fail — validation command failed"
    fi

    printf '### QA verification — issue #%s\n\n**Phase 1: Acceptance criteria**\n%s\n**Phase 4: validation_cmd**\n%s\n\n**Verdict:** %s\n' \
        "$issue_num" "$phase1_body" "$phase4_body" "$verdict_line"
}

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

# ── Linked issue + AC extraction ────────────────────────────────────────────

# Resolve linked issue from PR body ("Closes/Fixes/Resolves #N").
_PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
LINKED_ISSUE_NUM=$(_qa_linked_issue "$_PR_BODY")

ISSUE_BODY=""
if [ -n "$LINKED_ISSUE_NUM" ]; then
    ISSUE_BODY=$(backend_issue_view "$REPO" "$LINKED_ISSUE_NUM" --json body --jq .body 2>/dev/null || echo "")
    log "linked issue #${LINKED_ISSUE_NUM} found; body length=${#ISSUE_BODY}"
fi

# Extract ## Acceptance Criteria checkboxes using an inline python3 snippet.
AC_LIST=$(ISSUE_BODY="$ISSUE_BODY" python3 -c "
import os, re
body = os.environ.get('ISSUE_BODY', '').strip()
match = re.search(r'(?m)^\#{1,3}\s+Acceptance Criteria\s*$', body)
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
" 2>/dev/null || echo "__NO_AC_SECTION__")

if [ "$AC_LIST" = "__NO_AC_SECTION__" ]; then
    log "no ## Acceptance Criteria section found in linked issue — falling back to validation_cmd only"
    AC_SECTION="(No acceptance criteria found — falling back to validation_cmd only)"
    AC_INSTRUCTION=""
else
    log "extracted AC list from issue #${LINKED_ISSUE_NUM}"
    AC_SECTION="## Acceptance Criteria (from issue #${LINKED_ISSUE_NUM})

${AC_LIST}"
    AC_INSTRUCTION="For each numbered criterion above, output exactly one of:
- VERIFIED — the diff satisfies this criterion; provide a one-line rationale and, where mechanical, a proof command with expected output.
- NOT_FOUND — the diff does not address this criterion; quote what is missing.
- PARTIAL — partially addressed; explain what is done and what is still missing.

If ANY criterion is NOT_FOUND or PARTIAL the final verdict must be qa-fail."
fi

# ── Validation command section ───────────────────────────────────────────────

QA_TIMEOUT="${QA_TIMEOUT_SECONDS:-600}"
if [ -n "${QA_VALIDATION_CMD:-}" ]; then
    VALIDATION_SECTION="## Phase 4: validation_cmd

Run the project validation command (timeout ${QA_TIMEOUT}s):
  cd ${ROOT} && timeout ${QA_TIMEOUT} bash -c \"${QA_VALIDATION_CMD}\"

If this exits non-zero, the verdict must be qa-fail even if all ACs are VERIFIED."
else
    VALIDATION_SECTION="## Phase 4: validation_cmd

No validation_cmd is configured for this project. Skip this phase."
fi

# No validation_cmd — auto-pass without invoking the agent.
if [ -z "${QA_VALIDATION_CMD:-}" ]; then
    log "no qa.validation_cmd configured for $SLUG — auto-passing"
    _HAS_AC="no"
    _AC_LIST_COMMENT=""
    if [ "$AC_LIST" != "__NO_AC_SECTION__" ]; then
        _HAS_AC="yes"
        _AC_LIST_COMMENT="$AC_LIST"
    fi
    _QA_COMMENT=$(_qa_build_comment "${LINKED_ISSUE_NUM:-0}" "qa-pass" "" "$_AC_LIST_COMMENT" "$_HAS_AC")
    backend_comment_pr "$REPO" "$PR_NUM" "$_QA_COMMENT" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_remove_label "$REPO" "$PR_NUM" qa-failed
    backend_remove_label "$REPO" "$PR_NUM" qa-fail
    backend_remove_label "$REPO" "$PR_NUM" qa-pass
    backend_add_label "$REPO" "$PR_NUM" qa-pass
    exit 0
fi

# ── Agent prompt ─────────────────────────────────────────────────────────────

_BACKEND_CLI_NOTE=$(backend_cli_note)
_PROMPT_FILE=$(mktemp /tmp/qa-prompt-XXXXXX.txt)
cat > "$_PROMPT_FILE" <<EOF
You are the QA agent for ${NAME} (slug: ${SLUG}).
Project root: ${ROOT}
Repo: ${REPO}

READ ${ROOT}/CLAUDE.md first for project conventions.
If CLAUDE.md is missing, proceed with general best-practice conventions.

You are reviewing pull request #${PR_NUM} for QA.

Your job — do all of these in sequence:

0. Check PR state before proceeding:
   gh pr view ${PR_NUM} --repo ${REPO} --json state,merged
   If state=MERGED or state=CLOSED: remove labels needs-qa and ready-for-qa, leave a brief comment, and stop.

1. Fetch the PR diff:
   gh pr diff ${PR_NUM} --repo ${REPO}

2. Evaluate acceptance criteria:

${AC_SECTION}

${AC_INSTRUCTION}

3. ${VALIDATION_SECTION}

4. Post a structured comment on the PR using this template:

\`\`\`
### QA verification — issue #${LINKED_ISSUE_NUM:-N/A}

**Phase 1: Acceptance criteria**
<numbered AC results with VERIFIED/NOT_FOUND/PARTIAL and rationale>

**Phase 4: validation_cmd**
<result of running validation_cmd, or "skipped — not configured">

**Verdict:** <qa-pass or qa-fail — one-line reason>
\`\`\`

   Post the comment:
   gh pr comment ${PR_NUM} --repo ${REPO} --body '<the structured comment>'

5. Apply labels based on the verdict:

   If qa-pass (all ACs VERIFIED and validation_cmd passed or not configured):
     gh pr edit ${PR_NUM} --repo ${REPO} --remove-label needs-qa --remove-label ready-for-qa --remove-label qa-failed --remove-label qa-fail --remove-label qa-pass --add-label qa-pass

   If qa-fail (any AC NOT_FOUND/PARTIAL or validation_cmd failed):
     gh pr edit ${PR_NUM} --repo ${REPO} --remove-label needs-qa --remove-label ready-for-qa --remove-label approved --remove-label qa-pass --remove-label qa-failed --add-label qa-fail

IMPORTANT: You MUST finish by applying either 'qa-pass' or 'qa-fail'. The pipeline stalls if neither is applied. Verify with:
   gh pr view ${PR_NUM} --repo ${REPO} --json labels

Report the verdict and why in 2 sentences.
${_BACKEND_CLI_NOTE}
$(loop_cli_hint)
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

# ── Run agent ────────────────────────────────────────────────────────────────

if loop_run_agent "$TASK_PROMPT" "$ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    log "qa agent succeeded for PR #$PR_NUM"
    bounty_report "qa_pass" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    # Belt-and-braces: if agent forgot to apply a decision label, default to qa-fail
    # so the PR doesn't silently disappear from the pipeline.
    if ! backend_pr_has_any_label "$REPO" "$PR_NUM" qa-pass qa-fail blocked 'done'; then
        log "WARN: PR #$PR_NUM has no qa decision label after agent — defaulting to qa-fail"
        backend_remove_label "$REPO" "$PR_NUM" needs-qa
        backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
        backend_add_label "$REPO" "$PR_NUM" qa-fail
    fi
    loop_notify "✅ [$SLUG] PR#$PR_NUM qa done"
else
    log "qa agent failed for PR #$PR_NUM"
    bounty_report "qa_fail" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "❌ [$SLUG] PR#$PR_NUM qa failed: agent error"
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_remove_label "$REPO" "$PR_NUM" approved
    backend_remove_label "$REPO" "$PR_NUM" qa-pass
    backend_remove_label "$REPO" "$PR_NUM" qa-failed
    backend_add_label "$REPO" "$PR_NUM" qa-fail
    backend_comment_pr "$REPO" "$PR_NUM" \
        "QA agent failed. See loop-qa-handler.log for details."
    exit 1
fi
