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

# Per-project lock — one Loop handler at a time per repo (same-machine + same-repo
# share state: working tree, GitHub rate bucket, label race windows).
# Cross-repo parallelism is preserved — different slugs don't block each other.
source "$LOOP_ROOT/lib/lock.sh"
loop_acquire_lock "$SLUG" || { log "ERROR: couldn't acquire lock for $SLUG within 1hr — exiting"; exit 1; }
log "acquired project lock for $SLUG"

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

# Claim so scanner doesn't re-emit
backend_remove_label "$REPO" "$ISSUE_NUM" po-review
backend_add_label "$REPO" "$ISSUE_NUM" in-progress

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

IMPORTANT: The issue MUST end this run with exactly ONE of: dev / needs-clarification / blocked / tracker / closed.
Verify: gh issue view ${ISSUE_NUM} --repo ${REPO} --json labels,state
Report your decision (A/B/C/D/E/F) and why in 2 sentences.
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

_post_failure_comment() {
    local target_type="$1" target_num="$2" label_ctx="$3" _attempt="$4" max="$5"
    local body_file; body_file=$(mktemp /tmp/loop-fail-XXXXXX.md)
    {
        echo "Automated ${label_ctx} failed ${max} times. Needs human clarification."
        echo ""
        echo "<details><summary>Last agent output</summary>"
        echo ""
        echo '```'
        tail -n +"$((LOG_CAPTURE_START + 1))" "$LOG_FILE" \
            | sed 's/\(ANTHROPIC_API_KEY=\|GITHUB_TOKEN=\|GH_TOKEN=\|_SECRET=\)[^ ]*/\1REDACTED/g' \
            | tail -40
        echo '```'
        echo "</details>"
    } > "$body_file"
    if [ "$target_type" = "issue" ]; then
        gh issue comment "$target_num" --repo "$REPO" --body-file "$body_file" 2>/dev/null || true
    else
        gh pr comment "$target_num" --repo "$REPO" --body-file "$body_file" 2>/dev/null || true
    fi
    rm -f "$body_file"
}

LOG_CAPTURE_START=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
if loop_run_agent "$TASK_PROMPT" "$ROOT" 2>&1 | tee -a "$LOG_FILE"; then
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
