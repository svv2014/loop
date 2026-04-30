#!/usr/bin/env bash
# po-handler.sh — handles one loop.po_review event.
# Deprecated name: prefer scripts/planner.sh
#
# Event payload: {"slug","repo","issue_number","issue_title","issue_url"}
#
# Takes a rough "[IDEA]" issue labeled with the workflow's PO trigger,
# invokes a Product Owner agent that expands the body into a full spec
# (goal, acceptance criteria, file scope, dependencies), rewrites the issue
# body, and swaps the label to the dev trigger so the scanner picks it up
# next tick.

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
# shellcheck source=../lib/labels.sh
source "$LOOP_ROOT/lib/labels.sh"
# shellcheck source=../lib/bounty.sh
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/cli-hint.sh
source "$LOOP_ROOT/lib/cli-hint.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-po-handler.log"
MAX_RETRIES=2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [po-handler] $*" | tee -a "$LOG_FILE"; }

SLUG="${LOOP_SLUG:-}"
ISSUE_NUM="${LOOP_ISSUE_NUMBER:-}"
ISSUE_TITLE="${LOOP_ISSUE_TITLE:-}"
ISSUE_URL="${LOOP_ISSUE_URL:-}"

if [ -z "$SLUG" ] || [ -z "$ISSUE_NUM" ]; then
    EVENT_JSON="${LOOP_EVENT_JSON:-}"
    if [ -z "$EVENT_JSON" ] && [ ! -t 0 ]; then
        EVENT_JSON=$(cat)
    fi
    if [ -n "$EVENT_JSON" ]; then
        SLUG=$(echo "$EVENT_JSON"        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('slug',''))")
        ISSUE_NUM=$(echo "$EVENT_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('issue_number',''))")
        ISSUE_TITLE=$(echo "$EVENT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('issue_title',''))")
        ISSUE_URL=$(echo "$EVENT_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('issue_url',''))")
    fi
fi

[ -n "$SLUG" ] && [ -n "$ISSUE_NUM" ] \
    || { log "ERROR: missing slug or issue_number"; exit 2; }

loop_load_project "$SLUG" || { log "ERROR: unknown slug '$SLUG'"; exit 2; }
loop_load_backend

_po_trigger=$(loop_label_for "$SLUG" "$LOOP_LABEL_DEPRECATED_PO_REVIEW")
_REWORK_LABEL=$(loop_label_for "$SLUG" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK")

# Per-issue lock — PO writes only to one issue's body and labels, so two PO
# workers on different issues in the same project are safe in parallel. The
# lock still serializes duplicate dispatches for the same issue.
source "$LOOP_ROOT/lib/lock.sh"
loop_acquire_lock "po-${SLUG}-${ISSUE_NUM}" || { log "ERROR: couldn't acquire lock for po-${SLUG}-${ISSUE_NUM} within 1hr — exiting"; exit 1; }
log "acquired po lock for $SLUG #$ISSUE_NUM"

RETRY_FILE="/tmp/loop-po-retries-${SLUG}-${ISSUE_NUM}"
retry_count() { [ -f "$RETRY_FILE" ] && cat "$RETRY_FILE" || echo 0; }
retry_incr()  { local n; n=$(( $(retry_count) + 1 )); echo "$n" > "$RETRY_FILE"; echo "$n"; }
retry_clear() { rm -f "$RETRY_FILE"; }

retries=$(retry_count)
if [ "$retries" -ge "$MAX_RETRIES" ]; then
    log "issue #$ISSUE_NUM already failed PO ${retries}x — labeling needs-clarification"
    backend_remove_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    backend_add_label "$REPO" "$ISSUE_NUM" needs-clarification
    exit 0
fi

log "po: slug=$SLUG repo=$REPO issue=#$ISSUE_NUM attempt=$((retries + 1))/$MAX_RETRIES"
bounty_report "po_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=po project="$SLUG" issue_num="$ISSUE_NUM" || true
loop_notify "▶️ [$SLUG] #$ISSUE_NUM ${LOOP_LABEL_DEPRECATED_PO_REVIEW} starting"

# Claim so scanner doesn't re-emit: strip workflow trigger label before adding in-progress
# so the issue never carries both simultaneously.
backend_remove_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
backend_add_label "$REPO" "$ISSUE_NUM" in-progress

# Safety net: restore the workflow PO trigger if killed or set -e fires before explicit cleanup.
_IN_PROGRESS_CLAIMED=1
_po_label_cleanup() {
    [ "${_IN_PROGRESS_CLAIMED:-0}" = "1" ] || return 0
    log "EXIT trap: clearing orphaned in-progress on #$ISSUE_NUM — restoring to ${_po_trigger}"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress 2>/dev/null || true
    backend_add_label "$REPO" "$ISSUE_NUM" "$_po_trigger" 2>/dev/null || true
}
trap '_po_label_cleanup' EXIT TERM INT

ISSUE_BODY=$(backend_issue_view "$REPO" "$ISSUE_NUM" --json body --jq .body 2>/dev/null || echo "")

# Extract the true original body — strips any existing ## Original brief section
# so re-triaging an already-expanded issue doesn't nest markers.
_ORIGINAL_BRIEF=$(BODY="$ISSUE_BODY" python3 -c "
import os, re
body = os.environ.get('BODY', '').strip()
# Strip existing marker and everything after it
body = re.split(r'(?m)^---\s*\n##\s+Original brief', body)[0].rstrip()
print(body)
")

if [ -n "$_ORIGINAL_BRIEF" ]; then
    _ORIG_BRIEF_SECTION="After writing the full spec body above to /tmp/po-${ISSUE_NUM}-body.md, append the following to the file:

---

## Original brief (preserved by PO)

${_ORIGINAL_BRIEF}
"
else
    _ORIG_BRIEF_SECTION="(original body was empty — no brief preserved)"
fi

# Include recent comments so human steering + prior blocker context is visible to the PO agent.
ISSUE_COMMENTS=$(backend_issue_view "$REPO" "$ISSUE_NUM" --json comments 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    comments = d.get('comments', [])[-6:]  # last 6
    for c in comments:
        author = c.get('author', {}).get('login', '?')
        body = c.get('body', '').strip()
        ts = c.get('createdAt', '')
        if body and 'PO agent expanded the scope' not in body:
            print(f'[{ts}] {author}:\n{body}\n---')
except Exception:
    pass
" || echo "")

# Detect in-flight PR/MR for this issue — must run before building the prompt
# so the preamble block can be injected when an open MR exists.
# Degrades gracefully when backend_find_pr_for_issue is not yet available.
_IN_FLIGHT_PR=""
_MR_PREAMBLE=""
_MR_PATHS=""
_in_flight_pr_num=$(backend_find_pr_for_issue "$REPO" "$ISSUE_NUM" 2>/dev/null || echo "")
if [ -n "$_in_flight_pr_num" ]; then
    _pr_state=$(backend_pr_view "$REPO" "$_in_flight_pr_num" \
        --json state --jq '.state' 2>/dev/null || echo "")
    if [ "$_pr_state" = "OPEN" ]; then
        _IN_FLIGHT_PR="$_in_flight_pr_num"
        _pr_meta=$(backend_pr_view "$REPO" "$_IN_FLIGHT_PR" \
            --json title,headRefName,state,additions,deletions,changedFiles \
            2>/dev/null || echo "{}")
        _pr_title=$(echo "$_pr_meta" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('title',''))" \
            2>/dev/null || echo "")
        _pr_branch=$(echo "$_pr_meta" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('headRefName',''))" \
            2>/dev/null || echo "")
        _pr_additions=$(echo "$_pr_meta" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('additions','?'))" \
            2>/dev/null || echo "?")
        _pr_deletions=$(echo "$_pr_meta" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('deletions','?'))" \
            2>/dev/null || echo "?")
        _pr_files=$(echo "$_pr_meta" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('changedFiles','?'))" \
            2>/dev/null || echo "?")
        _pr_reviews=$(backend_pr_view "$REPO" "$_IN_FLIGHT_PR" \
            --json reviews --jq '.reviews[-5:][].body' 2>/dev/null \
            || echo "(no review comments)")
        log "in-flight PR #${_IN_FLIGHT_PR} found for issue #${ISSUE_NUM} (branch: ${_pr_branch})"
        _MR_PREAMBLE="--- EXISTING IMPLEMENTATION IN FLIGHT ---
PR #${_IN_FLIGHT_PR}: ${_pr_title}
Branch: ${_pr_branch}
State: OPEN
Diff stat: +${_pr_additions} lines, -${_pr_deletions} lines, ${_pr_files} files changed

Last review comments (up to 5 most recent):
${_pr_reviews}
--- END IN-FLIGHT CONTEXT ---

"
        _MR_PATHS="
G - REFINE-WITH-ACTIVE-MR (spec adjustment small enough the current MR can absorb it):
   - Comment on the MR: gh pr comment ${_IN_FLIGHT_PR} --repo ${REPO} --body 'PO: spec refinement: [details]'
   - Flag MR for rework: gh pr edit ${_IN_FLIGHT_PR} --repo ${REPO} --add-label ${_REWORK_LABEL}
   - Leave issue label at dev (no label change on issue)

H - SUPERSEDE (requirements changed enough the MR is wrong — wrong approach or stale spec):
   - Comment on MR: gh pr comment ${_IN_FLIGHT_PR} --repo ${REPO} --body 'PO: closing — superseded by new spec. [Explanation].'
   - Close MR: gh pr close ${_IN_FLIGHT_PR} --repo ${REPO}
   - Rewrite issue spec using SPEC FORMAT below
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --add-label dev

I - EXPAND-CROSS-PROJECT (MR implementation is correct but related work needed elsewhere):
   - Do not touch the current MR
   - Create new child issues for the related work, each labeled ${_po_trigger}
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: MR looks correct. Filed related work: #X, #Y.'
   - Leave issue label unchanged

J - ACCEPT-AS-IS (comment was informational only — no spec or MR change needed):
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: acknowledged. No action required.'
   - No label changes on issue or MR

When an MR is in flight, prefer G/H/I/J over A-F where appropriate.
"
    fi
fi

_report_line="Report your decision (A/B/C/D/E/F) and why in 2 sentences."
if [ -n "$_IN_FLIGHT_PR" ]; then
    _report_line="Report your decision (A/B/C/D/E/F/G/H/I/J) and why in 2 sentences."
fi

_BACKEND_CLI_NOTE=$(backend_cli_note)
_PROMPT_FILE=$(mktemp /tmp/po-prompt-XXXXXX.txt)
cat > "$_PROMPT_FILE" <<EOF
You are the Product Owner agent for ${NAME} (slug: ${SLUG}).
Project root: ${ROOT}
Repo: ${REPO}

READ ${ROOT}/CLAUDE.md first for project context, conventions, and scope rules.
If CLAUDE.md is missing or empty, proceed with the issue text alone and note the absence in the spec under ## Notes.

You have been given GitHub issue #${ISSUE_NUM}: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

${_MR_PREAMBLE}Current body:
${ISSUE_BODY}

Recent comments (most recent last) — may include human steering, blocker context from prior dev attempts, or supplementary scope:
${ISSUE_COMMENTS}

Your job: triage this ticket and decide what to do with it. You have full authority over the ticket lifecycle.

STEP 1 — Read the context:
- cd ${ROOT} && read CLAUDE.md
- Check if similar issues are already open or recently closed: gh issue list --repo ${REPO} --state all --limit 50
- Read the rework history in comments (look for "Rework attempt" comments)

STEP 2 — Choose a decision path:

A - EXPAND AND QUEUE (default: idea is clear, not duplicate, achievable in 1 day or less):
   - Rewrite the issue body with the spec below
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --body-file /tmp/po-${ISSUE_NUM}-body.md
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: spec written. Queuing for implementation.'
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --add-label dev

B - CLOSE AS DUPLICATE (issue already exists or was recently merged):
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: closing as duplicate of #N.'
   - gh issue close ${ISSUE_NUM} --repo ${REPO} --reason "not planned"

C - CANCEL / OUT OF SCOPE (idea contradicts project goals, irrelevant, or explicitly unwanted):
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: closing out of scope. Reason: [explain].'
   - gh issue close ${ISSUE_NUM} --repo ${REPO} --reason "not planned"

D - UPGRADE TO EPIC (idea is too big for one dev cycle, more than 1 day of work):
   - Convert this issue to a tracker/epic (add label "tracker")
   - Create 2-4 child issues, each scoped to less than 1 day, each with "${_po_trigger}" label
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --add-label tracker --remove-label in-progress --remove-label ${_po_trigger}
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: decomposed into child issues: #X, #Y, #Z.'

E - NEEDS CLARIFICATION (request is ambiguous, one specific question can unblock it):
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: needs clarification: [one specific question].'
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --add-label needs-clarification

F - REWORK RECOVERY (ticket has rework history, 1 or more failed rework attempts in comments):
   Read what failed. Then decide:
   - If spec was too vague: rewrite spec more precisely and re-queue (path A with improved spec)
   - If implementation approach was wrong: add an "Implementation Hint" section to spec and re-queue
   - If ticket is fundamentally broken: cancel (path C)
   - If 3 or more failed rework attempts: label blocked and notify:
     gh issue edit ${ISSUE_NUM} --repo ${REPO} --add-label blocked --remove-label in-progress
     Comment: "PO: 3+ rework attempts failed. Flagging blocked for human review."
${_MR_PATHS}
SPEC FORMAT (for paths A and F-requeue):

## Objective
One or two sentences stating the goal and the motivation.

## Acceptance Criteria
Testable checkboxes. A developer should be able to self-verify each. 3-6 bullets.

## Files & Scope
Which files/dirs the worker should touch; which it must NOT touch. Reference the actual repo layout.

## Dependencies
Any issues or infra that must land first. If none, write "None".

## Implementation Hint (optional, add when prior attempts failed)
What approach to take or avoid, based on rework history.

## Notes
Any gotchas, relevant prior art, or constraints pulled from CLAUDE.md.

## Out of scope
What this ticket explicitly does not cover. Prevents scope creep.

ORIGINAL BRIEF PRESERVATION (for path A spec writes):
${_ORIG_BRIEF_SECTION}

IMPORTANT: The issue MUST end this run with exactly ONE of: dev / needs-clarification / blocked / tracker / closed.
Verify: gh issue view ${ISSUE_NUM} --repo ${REPO} --json labels,state
${_report_line}
${_BACKEND_CLI_NOTE}
$(loop_cli_hint)
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

_post_failure_comment() {
    local target_type="$1" target_num="$2" label_ctx="$3" _attempt="$4" max="$5"
    # Post only a short marker — never the agent log/prompt, which contains
    # internal pipeline instructions that must not become public.
    local body="Automated ${label_ctx} failed ${max} times. Needs human clarification. Operator: see ${LOG_FILE} for the agent transcript."
    if [ "$target_type" = "issue" ]; then
        backend_comment_issue "$REPO" "$target_num" "$body" 2>/dev/null || true
    else
        backend_comment_pr "$REPO" "$target_num" "$body" 2>/dev/null || true
    fi
}

if loop_run_agent "$TASK_PROMPT" "$ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    _IN_PROGRESS_CLAIMED=0  # disarm trap — success path handles cleanup
    log "po agent succeeded for #$ISSUE_NUM"
    bounty_report "po_done" model="${LOOP_AGENT_MODEL:-sonnet}" role=po project="$SLUG" issue_num="$ISSUE_NUM" || true
    loop_notify "✅ [$SLUG] #$ISSUE_NUM ${LOOP_LABEL_DEPRECATED_PO_REVIEW} done"
    retry_clear
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    # Belt-and-braces: if agent forgot to apply progression label, add 'dev' as safe default.
    if ! backend_issue_has_any_label "$REPO" "$ISSUE_NUM" dev needs-clarification blocked tracker 'done'; then
        log "WARN: issue #$ISSUE_NUM has no progression label after PO agent — adding 'dev'"
        backend_add_label "$REPO" "$ISSUE_NUM" dev
    fi
else
    _IN_PROGRESS_CLAIMED=0  # disarm trap — failure path handles cleanup
    n=$(retry_incr)
    log "po agent failed for #$ISSUE_NUM (attempt $n/$MAX_RETRIES)"
    bounty_report "po_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=po project="$SLUG" issue_num="$ISSUE_NUM" detail="attempt ${n}/${MAX_RETRIES}" || true
    if [ "$n" -ge "$MAX_RETRIES" ]; then
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
        backend_add_label "$REPO" "$ISSUE_NUM" needs-clarification
        _post_failure_comment issue "$ISSUE_NUM" "PO agent" "$n" "$MAX_RETRIES"
        loop_notify "❌ [$SLUG] #$ISSUE_NUM ${LOOP_LABEL_DEPRECATED_PO_REVIEW} failed: agent failed after $MAX_RETRIES attempts"
    else
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
        backend_add_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
    fi
    exit 1
fi
