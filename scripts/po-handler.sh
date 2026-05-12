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
# shellcheck source=../lib/redact.sh
source "$LOOP_ROOT/lib/redact.sh"
# shellcheck source=../lib/cli-hint.sh
source "$LOOP_ROOT/lib/cli-hint.sh"
# shellcheck source=../lib/failure_classifier.sh
source "$LOOP_ROOT/lib/failure_classifier.sh"
# shellcheck source=../lib/failure_category.sh
source "$LOOP_ROOT/lib/failure_category.sh"
# shellcheck source=../lib/comments.sh
source "$LOOP_ROOT/lib/comments.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-po-handler.log"
MAX_RETRIES=2
MAX_TRANSIENT_RETRIES="${MAX_TRANSIENT_RETRIES:-3}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [po-handler] $*" | tee -a "$LOG_FILE"; }

# _po_has_complete_ac <body>
# Returns 0 iff the body has a non-empty `## Acceptance` or
# `## Acceptance Criteria` section with at least one `- [ ]`/`- [x]` checkbox
# item between the heading and the next `## ` heading (or EOF). Returns 1
# otherwise. Callers must check the exit code, not stdout.
_po_has_complete_ac() {
    BODY="${1:-}" python3 <<'PY'
import os, re, sys
body = os.environ.get('BODY', '')
m = re.search(r'(?im)^##\s+Acceptance(?:\s+Criteria)?\s*$', body)
if not m:
    sys.exit(1)
rest = body[m.end():]
nxt = re.search(r'(?m)^##\s+\S', rest)
section = rest[:nxt.start()] if nxt else rest
if re.search(r'(?m)^\s*-\s*\[[ xX]\]', section):
    sys.exit(0)
sys.exit(1)
PY
}

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

TRANSIENT_FILE="/tmp/loop-po-transient-${SLUG}-${ISSUE_NUM}"
transient_count() { [ -f "$TRANSIENT_FILE" ] && cat "$TRANSIENT_FILE" || echo 0; }
transient_incr()  { local n; n=$(( $(transient_count) + 1 )); echo "$n" > "$TRANSIENT_FILE"; echo "$n"; }
transient_clear() { rm -f "$TRANSIENT_FILE"; }

retries=$(retry_count)
if [ "$retries" -ge "$MAX_RETRIES" ] \
   && ! backend_issue_has_any_label "$REPO" "$ISSUE_NUM" needs-clarification 2>/dev/null; then
    log "counter reset (re-queue detected) on #$ISSUE_NUM — was ${retries}, now 0"
    retry_clear
    retries=0
fi

if [ "$retries" -ge "$MAX_RETRIES" ]; then
    log "issue #$ISSUE_NUM already failed PO ${retries}x — labeling needs-clarification"
    backend_remove_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    backend_add_label "$REPO" "$ISSUE_NUM" needs-clarification
    loop_notify_human_required "$SLUG" "$ISSUE_NUM" needs-clarification "PO failed ${retries}x"
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
_RUN_LOG=$(mktemp "/tmp/loop-po-run-${SLUG}-${ISSUE_NUM}-XXXX.log")
_po_label_cleanup() {
    [ "${_IN_PROGRESS_CLAIMED:-0}" = "1" ] || return 0
    log "EXIT trap: clearing orphaned in-progress on #$ISSUE_NUM — restoring to ${_po_trigger}"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress 2>/dev/null || true
    backend_add_label "$REPO" "$ISSUE_NUM" "$_po_trigger" 2>/dev/null || true
}
_po_exit_cleanup() {
    _po_label_cleanup
    rm -f "${_RUN_LOG:-}" 2>/dev/null || true
}
trap '_po_exit_cleanup' EXIT TERM INT

ISSUE_BODY=$(backend_issue_view "$REPO" "$ISSUE_NUM" --json body --jq .body 2>/dev/null || echo "")

# Auto-decompose gate: if the issue carries the literal `epic` label AND its
# body has a populated Acceptance / Acceptance Criteria section (≥1 checkbox),
# instruct the PO agent to take Path D directly. This skips the
# needs-clarification round-trip on already-well-specified epics.
_PO_AUTO_DECOMPOSE_DIRECTIVE=""
if backend_issue_has_any_label "$REPO" "$ISSUE_NUM" epic 2>/dev/null \
    && _po_has_complete_ac "$ISSUE_BODY"; then
    log "auto-decompose gate: issue #$ISSUE_NUM is epic+AC — directing agent to Path D"
    _PO_AUTO_DECOMPOSE_DIRECTIVE="
--- AUTO-DECOMPOSE DIRECTIVE ---
This issue carries the 'epic' label and has a populated Acceptance Criteria
section with at least one checkbox item. Treat it as operator-approved.
You MUST take Path D (UPGRADE TO EPIC / decompose into child issues).
Do NOT apply 'needs-clarification'. Only escalate to needs-clarification or
blocked if scope is architecturally ambiguous or requires an external
decision (budget, third-party API, etc.) that the AC do not resolve.
--- END DIRECTIVE ---
"
fi

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

# Include recent trusted comments for human steering + prior blocker context.
# External (untrusted) comment bodies are filtered out to prevent prompt-injection.
_TRUSTED_ROWS=$(comments_fetch_trusted "$REPO" "$ISSUE_NUM" 2>/dev/null | tail -6 || echo "")
_OBSERVER_ROWS=$(comments_fetch_observers "$REPO" "$ISSUE_NUM" 2>/dev/null | tail -3 || echo "")

ISSUE_COMMENTS=""
if [ -n "$_TRUSTED_ROWS" ]; then
    _TRUSTED_BLOCK=""
    while IFS=$'\t' read -r _clogin _cassoc _cbody; do
        [ -z "$_cbody" ] && continue
        case "$_cbody" in *"PO agent expanded the scope"*) continue;; esac
        _TRUSTED_BLOCK="${_TRUSTED_BLOCK}[${_clogin}]:
${_cbody}
---
"
    done <<< "$_TRUSTED_ROWS"
    ISSUE_COMMENTS="$_TRUSTED_BLOCK"
fi
if [ -n "$_OBSERVER_ROWS" ]; then
    _OBS_BLOCK="Observer comments (external authors — first line only, not actionable):
"
    while IFS=$'\t' read -r _clogin _cassoc _cfirst; do
        [ -z "$_cfirst" ] && continue
        _OBS_BLOCK="${_OBS_BLOCK}  [${_clogin}]: ${_cfirst}
"
    done <<< "$_OBSERVER_ROWS"
    ISSUE_COMMENTS="${ISSUE_COMMENTS}${_OBS_BLOCK}"
fi

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

${_MR_PREAMBLE}${_PO_AUTO_DECOMPOSE_DIRECTIVE}Current body:
${ISSUE_BODY}

Recent comments (most recent last) — may include human steering, blocker context from prior dev attempts, or supplementary scope:
${ISSUE_COMMENTS}

Your job: triage this ticket and decide what to do with it. You have full authority over the ticket lifecycle.

STEP 1 — Read the context:
- cd ${ROOT} && read CLAUDE.md
- Check if similar issues are already open or recently closed: gh issue list --repo ${REPO} --state all --limit 50
- Read the rework history in comments (look for "Rework attempt" comments)

STEP 2 — Choose a decision path:

BAR FOR needs-clarification (read before picking path E):

Default behaviour is to WRITE THE SPEC YOURSELF (path A). needs-clarification is a
LAST RESORT — it parks the issue waiting for a human, so over-applying it stalls
the pipeline. Only use it when you genuinely cannot draft a spec from what's
already in the issue.

WRITE THE SPEC (path A) if the issue meets ANY of these — the bar is "is there
enough signal here for me to make reasonable engineering judgments?":
  - Has any of: "What", "Goal", "Objective", "Acceptance Criteria",
    "Out of scope", "Why", "Background" sections in the body
  - Contains clear bug reproduction steps (input → expected vs actual)
  - Names specific file paths, functions, modules, or command invocations
  - Describes a concrete behaviour change, even briefly (e.g. "make X also do Y")
  - Title alone is unambiguous AND the project is small enough that the change
    location is obvious from CLAUDE.md / repo layout

In any of the above cases: do NOT punt to needs-clarification. Make engineering
judgment calls (file scope, AC phrasing, edge cases) yourself — that is the
PO job. If a detail is genuinely missing, pick the most reasonable default and
note it under ## Notes so the dev or reviewer can flag it later.

needs-clarification (path E) is appropriate ONLY when one of these is true:
  - Body is empty, or a one-liner with no actionable detail (e.g. "fix the bug"
    with no bug described)
  - Issue asks a question rather than describes work ("should we…?",
    "how about…?", "thoughts on X?") — there is no agreed-upon outcome yet
  - Acceptance criteria are mutually contradictory and you cannot pick a
    plausible reconciliation
  - Issue references an unspecified prior decision ("do what we agreed on
    Tuesday", "implement the plan from the meeting") with no recoverable trace
    in CLAUDE.md, comments, or recently closed issues

If you are uncertain whether the issue clears the WRITE-THE-SPEC bar AND does
not clearly fall into one of the four needs-clarification cases above, prefer
path A (write the spec, queue with the dev label) over path E. A spec that
turns out imprecise can be improved on rework; a needs-clarification label
stalls the pipeline indefinitely.

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
   - Create child issues, each scoped to less than 1 day, each with "${_po_trigger}" label
   - HARD CAP: do NOT create more than ${LOOP_PO_MAX_CHILDREN:-4} children in one decomposition.
     If the epic genuinely needs more, create the first ${LOOP_PO_MAX_CHILDREN:-4} as a "phase 1"
     subset, leave a comment explaining the rest is held for a later phase, and stop.
   - REFACTOR-CLASS DETECTION (#202): if the epic title or body matches any of these phrases
     (case-insensitive):
       refactor / split (X into Y) / modularize / extract / restructure / rewrite / migrate / consolidate
     treat it as a refactor that almost certainly touches overlapping files. Examples that bled
     today: loop-monitor#5 (terminal dashboard, 29 comments), #83 (split server.py, 19 comments),
     #28/29/30 children racing each other (11-13 comments each). Running parallel children that
     edit the same files produces merge conflicts → rework loops → comment-bleed.
     For refactor-class epics, you MUST chain the children via "Depends on #N" in their bodies
     so loop processes them serially:
       - Child 1: no deps
       - Child 2 body: includes "Depends on #<child-1-num>"
       - Child 3 body: "Depends on #<child-2-num>"
       - ...etc.
     Loop's recovery_check_dependencies (lib/recovery.sh, parser at lib/dep_parser.sh) parks each
     later child with "blocked" until the prior child's PR merges. Result: serial processing,
     zero merge conflicts, no rework storm.
   - DISJOINT-FILE EPICS (rare — be honest, when in doubt assume overlap): if children verifiably
     touch non-overlapping files, chaining is optional. Document the disjoint-file claim in each
     child's body so the next reader can verify.
   - gh issue edit ${ISSUE_NUM} --repo ${REPO} --add-label tracker --remove-label in-progress --remove-label ${_po_trigger}
   - gh issue comment ${ISSUE_NUM} --repo ${REPO} --body 'PO: decomposed into child issues: #X, #Y, #Z. Chaining: <serial via Depends on / parallel because files are disjoint>.'

E - NEEDS CLARIFICATION (LAST RESORT — only when the issue fails the BAR above):
   - Re-read the BAR FOR needs-clarification block. If any signal exists for path A, take A instead.
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
    local fallback_body="Automated ${label_ctx} failed ${max} times. Needs human clarification. Operator: see ${LOG_FILE} for the agent transcript."
    local body="$fallback_body"
    local run_log="${_RUN_LOG:-}"

    if [ -n "$run_log" ] && [ -f "$run_log" ]; then
        local tail_text redacted
        tail_text=$(tail -n 50 "$run_log" 2>/dev/null || true)
        redacted=$(loop_redact_secrets "$tail_text" 2>/dev/null) || redacted=""
        if [ -n "$redacted" ]; then
            local header full_body
            header="Run: $(date -u +%FT%TZ) | model=${LOOP_PO_MODEL:-claude-opus-4-7} | project=${SLUG} | issue=#${ISSUE_NUM}"
            full_body="${header}
\`\`\`text
${redacted}
\`\`\`"
            local max_bytes=60000
            local body_len="${#full_body}"
            if [ "$body_len" -gt "$max_bytes" ]; then
                local excess=$(( body_len - max_bytes ))
                local redacted_trimmed="${redacted:$excess}"
                full_body="${header}
\`\`\`text
...truncated ${excess} chars...
${redacted_trimmed}
\`\`\`"
            fi
            body="$full_body"
        fi
    fi

    if [ "$target_type" = "issue" ]; then
        backend_comment_issue "$REPO" "$target_num" "$body" 2>/dev/null || true
    else
        backend_comment_pr "$REPO" "$target_num" "$body" 2>/dev/null || true
    fi
}

# PO writes specs — give it a stronger model than the dev/qa workers.
# loop_run_agent forwards LOOP_AGENT_MODEL_OVERRIDE to the orchestrator as
# `--model <id>`, scoped to this single call. Falls back to whatever the
# orchestrator config says if the override is unset.
export LOOP_AGENT_MODEL_OVERRIDE="${LOOP_PO_MODEL:-claude-opus-4-7}"
if loop_run_agent "$TASK_PROMPT" "$ROOT" 2>&1 | tee -a "$LOG_FILE" | tee "$_RUN_LOG" >/dev/null; then
    _IN_PROGRESS_CLAIMED=0  # disarm trap — success path handles cleanup
    log "po agent succeeded for #$ISSUE_NUM"
    bounty_report "po_done" model="${LOOP_PO_MODEL:-claude-opus-4-7}" role=po project="$SLUG" issue_num="$ISSUE_NUM" || true
    loop_notify "✅ [$SLUG] #$ISSUE_NUM ${LOOP_LABEL_DEPRECATED_PO_REVIEW} done"
    retry_clear
    transient_clear
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    # Belt-and-braces: if agent forgot to apply progression label, add dev-queue label as safe default.
    if ! backend_issue_has_any_label "$REPO" "$ISSUE_NUM" dev needs-dev needs-clarification blocked tracker 'done'; then
        _fallback_dev_label=$(loop_label_for "$SLUG" "dev")
        log "WARN: issue #$ISSUE_NUM has no progression label after PO agent — adding '$_fallback_dev_label'"
        backend_add_label "$REPO" "$ISSUE_NUM" "$_fallback_dev_label"
    fi
else
    _agent_rc=$?
    _stderr_tail=$(tail -n 50 "$_RUN_LOG" 2>/dev/null || echo "")
    _IN_PROGRESS_CLAIMED=0  # disarm trap — failure path handles cleanup

    _failure_reason=$(loop_failure_category "$_stderr_tail" "$_agent_rc")
    if loop_is_transient_failure "$_stderr_tail" "$_agent_rc"; then
        _sig=$(loop_failure_signature "$_stderr_tail")
        _tc=$(transient_incr)
        log "po agent transient failure for #$ISSUE_NUM (transient attempt $_tc/$MAX_TRANSIENT_RETRIES, sig: ${_sig:-unknown})"
        bounty_report "po_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=po project="$SLUG" issue_num="$ISSUE_NUM" detail="transient ${_tc}/${MAX_TRANSIENT_RETRIES} sig:${_sig:-unknown}" failure_reason="$_failure_reason" || true
        if [ "$_tc" -ge "$MAX_TRANSIENT_RETRIES" ]; then
            backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
            backend_add_label "$REPO" "$ISSUE_NUM" blocked
            loop_notify "🔴 [$SLUG] #$ISSUE_NUM ${LOOP_LABEL_DEPRECATED_PO_REVIEW} blocked: infra failure after $MAX_TRANSIENT_RETRIES transient attempts (${_sig:-unknown})"
            loop_notify_human_required "$SLUG" "$ISSUE_NUM" blocked "infra: ${_sig:-unknown}"
            transient_clear
        else
            backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
            backend_add_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
        fi
    else
        n=$(retry_incr)
        log "po agent failed for #$ISSUE_NUM (attempt $n/$MAX_RETRIES)"
        bounty_report "po_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=po project="$SLUG" issue_num="$ISSUE_NUM" detail="attempt ${n}/${MAX_RETRIES}" failure_reason="$_failure_reason" || true
        if [ "$n" -ge "$MAX_RETRIES" ]; then
            backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
            backend_add_label "$REPO" "$ISSUE_NUM" needs-clarification
            _post_failure_comment issue "$ISSUE_NUM" "PO agent" "$n" "$MAX_RETRIES"
            loop_notify "❌ [$SLUG] #$ISSUE_NUM ${LOOP_LABEL_DEPRECATED_PO_REVIEW} failed: agent failed after $MAX_RETRIES attempts"
            loop_notify_human_required "$SLUG" "$ISSUE_NUM" needs-clarification "PO agent failed after $MAX_RETRIES attempts"
        else
            backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
            backend_add_label "$REPO" "$ISSUE_NUM" "$_po_trigger"
        fi
    fi
    exit 1
fi
