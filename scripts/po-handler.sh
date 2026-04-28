#!/usr/bin/env bash
# po-handler.sh — handles one loop.po_review event.
# Deprecated name: prefer scripts/planner.sh
#
# Event payload: {"slug","repo","issue_number","issue_title","issue_url"}
#
# Takes a rough "[IDEA]" issue labeled 'po-review', invokes a Product Owner
# agent that expands the body into a full spec (goal, acceptance criteria,
# file scope, dependencies), rewrites the issue body, and swaps the label
# from 'po-review' to 'dev' so the scanner picks it up next tick.

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
    backend_remove_label "$REPO" "$ISSUE_NUM" po-review
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    backend_add_label "$REPO" "$ISSUE_NUM" needs-clarification
    exit 0
fi

log "po: slug=$SLUG repo=$REPO issue=#$ISSUE_NUM attempt=$((retries + 1))/$MAX_RETRIES"
bounty_report "po_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=po project="$SLUG" issue_num="$ISSUE_NUM" || true
loop_notify "▶️ [$SLUG] #$ISSUE_NUM po-review starting"

# Claim so scanner doesn't re-emit: strip workflow trigger label before adding in-progress
# so the issue never carries both simultaneously.
_po_trigger=$(loop_label_for "$SLUG" "po-review")
backend_remove_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
backend_add_label "$REPO" "$ISSUE_NUM" in-progress

# Safety net: restore to po-review if killed or set -e fires before explicit cleanup.
_IN_PROGRESS_CLAIMED=1
_po_label_cleanup() {
    [ "${_IN_PROGRESS_CLAIMED:-0}" = "1" ] || return 0
    log "EXIT trap: clearing orphaned in-progress on #$ISSUE_NUM — restoring to po-review"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress 2>/dev/null || true
    backend_add_label "$REPO" "$ISSUE_NUM" po-review 2>/dev/null || true
}
trap '_po_label_cleanup' EXIT TERM INT

ISSUE_BODY=$(backend_issue_view "$REPO" "$ISSUE_NUM" --json body --jq .body 2>/dev/null || echo "")

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

# Detect any open PR/MR that closes this issue and inject its context into the prompt.
_INFLIGHT_PR_NUM=$(backend_find_pr_for_issue "$REPO" "$ISSUE_NUM" 2>/dev/null || true)
_INFLIGHT_PR_BLOCK=""
if [ -n "$_INFLIGHT_PR_NUM" ]; then
    log "found in-flight PR #$_INFLIGHT_PR_NUM for issue #$ISSUE_NUM — fetching context"
    _INFLIGHT_PR_BLOCK=$(backend_pr_view "$REPO" "$_INFLIGHT_PR_NUM" \
        --json number,title,headRefName,state,isDraft,reviewDecision,additions,deletions,changedFiles,reviews \
        2>/dev/null | python3 -c "
import json, sys
try:
    pr = json.load(sys.stdin)
    num    = pr.get('number', '?')
    title  = pr.get('title', '')
    branch = pr.get('headRefName', '')
    state  = pr.get('state', '')
    draft  = pr.get('isDraft', False)
    rd     = pr.get('reviewDecision', '') or ''
    adds   = pr.get('additions', 0)
    dels   = pr.get('deletions', 0)
    files  = pr.get('changedFiles', 0)
    reviews = pr.get('reviews', []) or []
    last_reviews = reviews[-5:] if len(reviews) > 5 else reviews
    state_str = state
    if draft:
        state_str = 'DRAFT'
    if rd:
        state_str += f' / review={rd}'
    lines = [
        'EXISTING IMPLEMENTATION IN FLIGHT',
        f'PR: #{num} — {title}',
        f'Branch: {branch}',
        f'State: {state_str}',
        f'Diff stat: {files} files changed, +{adds} -{dels}',
    ]
    if last_reviews:
        lines.append('Last review comments:')
        for r in last_reviews:
            author = (r.get('author') or {}).get('login', '?')
            body = (r.get('body') or '').strip()
            submitted = r.get('submittedAt', '')
            verdict = r.get('state', '')
            if body:
                lines.append(f'  [{submitted}] {author} ({verdict}): {body}')
    print('\n'.join(lines))
except Exception as e:
    sys.stderr.write(str(e) + '\n')
" 2>/dev/null || echo "")
    if [ -z "$_INFLIGHT_PR_BLOCK" ]; then
        _INFLIGHT_PR_BLOCK="EXISTING IMPLEMENTATION IN FLIGHT
PR: #${_INFLIGHT_PR_NUM} (context unavailable — check manually)"
    fi
fi

_PROMPT_FILE=$(mktemp /tmp/po-prompt-XXXXXX.txt)
cat > "$_PROMPT_FILE" <<EOF
You are the Product Owner agent for ${NAME} (slug: ${SLUG}).
Project root: ${ROOT}
Repo: ${REPO}

READ ${ROOT}/CLAUDE.md first for project context, conventions, and scope rules.
If CLAUDE.md is missing or empty, proceed with the issue text alone and note the absence in the spec under ## Notes.

You have been given GitHub issue #${ISSUE_NUM}: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

Current body:
${ISSUE_BODY}

Recent comments (most recent last) — may include human steering, blocker context from prior dev attempts, or supplementary scope:
${ISSUE_COMMENTS}

${_INFLIGHT_PR_BLOCK}

Your job: triage this ticket and decide what to do with it. You have full authority over the ticket lifecycle.

STEP 1 — Read the context:
- cd ${ROOT} && read CLAUDE.md
- Check if similar issues are already open or recently closed: gh issue list --repo ${REPO} --state all --limit 50
- Read the rework history in comments (look for "Rework attempt" comments)

STEP 2 — Choose a decision path:

A - EXPAND AND QUEUE (default: idea is clear, not duplicate, achievable in 1 day or less, NO in-flight PR):
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
   - Create 2-4 child issues, each scoped to less than 1 day, each with "po-review" label
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --add-label tracker --remove-label in-progress --remove-label po-review
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

--- PATHS FOR WHEN AN IN-FLIGHT PR EXISTS (use these when "EXISTING IMPLEMENTATION IN FLIGHT" appears above) ---

G - REFINE-WITH-ACTIVE-PR (spec adjustment needed but the existing PR can absorb it):
   The implementation is in progress and the refinement is small enough to be handled
   via a rework cycle rather than starting over.
   - Post a comment on the PR with the refinement details:
     gh pr comment ${_INFLIGHT_PR_NUM:-<PR_NUM>} --repo ${REPO} --body 'PO: refinement requested: [details].'
   - Apply needs-rework label to the PR so dev-rework-handler picks it up:
     gh pr edit ${_INFLIGHT_PR_NUM:-<PR_NUM>} --repo ${REPO} --add-label needs-rework
   - Leave the issue at its current label (dev or in-progress); do NOT re-add dev if already there.
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress

H - SUPERSEDE (requirements changed enough that the existing PR is wrong; start fresh):
   - Close the existing PR with an explanation:
     gh pr close ${_INFLIGHT_PR_NUM:-<PR_NUM>} --repo ${REPO} --comment 'PO: superseded by revised spec. Starting fresh.'
   - Rewrite the issue spec (use SPEC FORMAT below)
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --body-file /tmp/po-${ISSUE_NUM}-body.md
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --add-label dev

I - EXPAND-CROSS-PROJECT (existing PR is correct but related work is needed in sibling repos):
   - File new issues in the related repos with 'po-review' label, one issue per repo
   - Post a comment on this issue summarising what was filed:
     gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: filed related issues: [list].'
   - Leave the existing PR alone; remove in-progress from this issue and restore it to dev:
     gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --add-label dev

J - ACCEPT-AS-IS (comment was informational; no spec or PR change needed):
   - Post a short acknowledgment:
     gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: noted, no spec change needed.'
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --add-label dev

SPEC FORMAT (for paths A, F-requeue, and H):

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

IMPORTANT: The issue MUST end this run with exactly ONE of: dev / needs-clarification / blocked / tracker / closed.
Verify: gh issue view ${ISSUE_NUM} --repo ${REPO} --json labels,state
Report your decision (A/B/C/D/E/F/G/H/I/J) and why in 2 sentences.
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
    loop_notify "✅ [$SLUG] #$ISSUE_NUM po-review done"
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
        loop_notify "❌ [$SLUG] #$ISSUE_NUM po-review failed: agent failed after $MAX_RETRIES attempts"
    else
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
        backend_add_label "$REPO" "$ISSUE_NUM" po-review
    fi
    exit 1
fi
