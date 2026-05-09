#!/usr/bin/env bash
# review-handler.sh — handles one loop.pr_review event.
# Deprecated name: prefer scripts/reviewer.sh
#
# Event payload: {"slug","repo","pr_number","pr_title","pr_url"}
#
# Flow: label PR 'in-review' → invoke orchestrator with reviewer prompt →
# agent reviews diff + PR body against the issue being closed →
# applies 'needs-qa' on approve or the workflow's rework label on reject.

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
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/cli-hint.sh
source "$LOOP_ROOT/lib/cli-hint.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-review-handler.log"
MAX_RETRIES=2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [review-handler] $*" | tee -a "$LOG_FILE"; }

# Read event fields — prefer discrete env vars (set by router), fall back to JSON.
SLUG="${LOOP_SLUG:-}"
PR_NUM="${LOOP_PR_NUMBER:-}"
PR_TITLE="${LOOP_PR_TITLE:-}"
PR_URL="${LOOP_PR_URL:-}"

if [ -z "$SLUG" ] || [ -z "$PR_NUM" ]; then
    EVENT_JSON="${LOOP_EVENT_JSON:-}"
    if [ -z "$EVENT_JSON" ] && [ ! -t 0 ]; then
        EVENT_JSON=$(cat)
    fi
    if [ -n "$EVENT_JSON" ]; then
        SLUG=$(echo "$EVENT_JSON"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('slug',''))")
        PR_NUM=$(echo "$EVENT_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_number',''))")
        PR_TITLE=$(echo "$EVENT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_title',''))")
        PR_URL=$(echo "$EVENT_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_url',''))")
    fi
fi

[ -n "$SLUG" ] && [ -n "$PR_NUM" ] \
    || { log "ERROR: missing slug or pr_number"; exit 2; }

loop_load_project "$SLUG" || { log "ERROR: unknown slug '$SLUG'"; exit 2; }
loop_load_backend

# Resolve workflow-specific labels for this project so the agent prompt + the
# belt-and-braces apply the right names per active workflow.
_REVIEW_LABEL=$(loop_label_for "$SLUG" "needs-review")
_REWORK_LABEL=$(loop_label_for "$SLUG" "needs-rework")
_QA_LABEL=$(loop_label_for "$SLUG" "needs-qa")
_QA_PASS_LABEL=$(loop_label_for "$SLUG" "qa-pass")
_QA_FAIL_LABEL=$(loop_label_for "$SLUG" "qa-fail")

# shellcheck source=../lib/handler_guard.sh
source "$LOOP_ROOT/lib/handler_guard.sh"
if ! loop_handler_guard "$REPO" pr "$PR_NUM" "$_REVIEW_LABEL"; then
    log "guard: PR #$PR_NUM no longer eligible for review — skipping"
    exit 0
fi

# Auto-promote drafts — PRs are no longer opened as drafts, but promote any legacy ones.
_is_draft=$(gh pr view "$PR_NUM" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")
if [ "$_is_draft" = "true" ]; then
    log "PR #$PR_NUM is a draft — auto-promoting to ready"
    gh pr ready "$PR_NUM" --repo "$REPO" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" draft 2>/dev/null || true
fi

# PR-scoped lock — allows multiple PRs in the same project to be reviewed in parallel.
# (Review only reads from origin; no shared working tree state to protect.)
source "$LOOP_ROOT/lib/lock.sh"
loop_acquire_lock "${SLUG}-pr-${PR_NUM}" || { log "ERROR: couldn't acquire lock for ${SLUG}-pr-${PR_NUM} within 1hr — exiting"; exit 1; }
log "acquired PR lock for ${SLUG}-pr-${PR_NUM}"

RETRY_FILE="/tmp/loop-review-retries-${SLUG}-${PR_NUM}"
retry_count() { [ -f "$RETRY_FILE" ] && cat "$RETRY_FILE" || echo 0; }
retry_incr()  { local n; n=$(( $(retry_count) + 1 )); echo "$n" > "$RETRY_FILE"; echo "$n"; }
retry_clear() { rm -f "$RETRY_FILE"; }

retries=$(retry_count)
if [ "$retries" -ge "$MAX_RETRIES" ]; then
    log "PR #$PR_NUM already failed review ${retries}x — labeling ${_REWORK_LABEL}"
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_NEEDS_REVIEW"
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING"
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_IN_REVIEW"
    backend_remove_label "$REPO" "$PR_NUM" "$_REWORK_LABEL"
    backend_add_label "$REPO" "$PR_NUM" "$_REWORK_LABEL"
    exit 0
fi

log "review: slug=$SLUG repo=$REPO pr=#$PR_NUM attempt=$((retries + 1))/$MAX_RETRIES"
bounty_report "review_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=reviewer project="$SLUG" pr_num="$PR_NUM" || true
loop_notify "▶️ [$SLUG] PR#$PR_NUM review starting"

backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_NEEDS_REVIEW"
backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING"
backend_add_label "$REPO" "$PR_NUM" "$LOOP_LABEL_IN_REVIEW"

_BACKEND_CLI_NOTE=$(backend_cli_note)

_PROMPT_FILE=$(mktemp /tmp/review-prompt-XXXXXX.txt)
cat > "$_PROMPT_FILE" <<EOF
You are the Senior Code Reviewer for ${NAME} (slug: ${SLUG}).
Project root: ${ROOT}
Repo: ${REPO}

READ ${ROOT}/CLAUDE.md first for project conventions.
If CLAUDE.md is missing, proceed with general best-practice conventions and note the absence in your review comment.

You are reviewing pull request #${PR_NUM}: ${PR_TITLE}
URL: ${PR_URL}

Your job -- do all of these in sequence:

0. Check PR state before reviewing:
   gh pr view ${PR_NUM} --repo ${REPO} --json state,merged
   If state=MERGED or state=CLOSED: remove label 'in-review', leave a brief comment that this PR is already closed/merged, and stop. Do not proceed further.

1. cd ${ROOT} && git fetch origin
2. Fetch the PR details and diff:
   gh pr view ${PR_NUM} --repo ${REPO} --json title,body,headRefName,files,closingIssuesReferences
   gh pr diff ${PR_NUM} --repo ${REPO}
   If the diff is empty (no files changed), immediately REQUEST_CHANGES with the explanation that an empty diff cannot be reviewed.
3. Check CI status -- note any failing checks:
   gh pr checks ${PR_NUM} --repo ${REPO}
   If required checks are failing, REQUEST_CHANGES citing the failing checks (unless the failures are pre-existing and clearly unrelated to this PR scope -- document your reasoning if you choose to ignore them).
4. For every issue this PR claims to close, fetch the issue body and verify the acceptance criteria are met:
   gh issue view <N> --repo ${REPO} --json body,labels
5. Spot-check the diff: does the code match the issue spec? Any obvious bugs, regressions, or scope creep? Is the commit message / PR body aligned with CLAUDE.md conventions?
6. Decide: APPROVE or REQUEST_CHANGES.

If APPROVE:
   gh pr review ${PR_NUM} --repo ${REPO} --approve --body '<2-4 sentence summary of what looks good>'
   gh pr edit ${PR_NUM} --repo ${REPO} --remove-label in-review --remove-label ${_REVIEW_LABEL} --remove-label ${_QA_LABEL} --add-label ${_QA_LABEL}

If REQUEST_CHANGES:
   gh pr review ${PR_NUM} --repo ${REPO} --request-changes --body '<specific, actionable feedback -- what to change and why>'
   gh pr edit ${PR_NUM} --repo ${REPO} --remove-label in-review --remove-label ${_REVIEW_LABEL} --remove-label ${_REWORK_LABEL} --add-label ${_REWORK_LABEL}

Be strict but fair. Approve content-adjacent bookkeeping (formatting, docs) liberally. Push back on logic errors, security issues, missing tests where the issue asked for tests, or content that contradicts the cited source (e.g. a lesson that miscites CAR Part X).

IMPORTANT: You MUST finish by applying either '${_QA_LABEL}' or '${_REWORK_LABEL}' label. The pipeline stalls if neither is applied. Verify with:
   gh pr view ${PR_NUM} --repo ${REPO} --json labels

Report the decision you made and why, in 3 short sentences.
${_BACKEND_CLI_NOTE}
$(loop_cli_hint)
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

if loop_run_agent "$TASK_PROMPT" "$ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    log "review agent finished for PR #$PR_NUM"
    bounty_report "review_done" model="${LOOP_AGENT_MODEL:-sonnet}" role=reviewer project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "✅ [$SLUG] PR#$PR_NUM review done"
    retry_clear

    # Deterministic decision sync: trust GitHub's reviewDecision over the agent's label edits.
    _decision=$(backend_pr_view "$REPO" "$PR_NUM" --json reviewDecision --jq .reviewDecision 2>/dev/null || echo "")
    # jq prints "null" when the field is absent — treat that as empty/fallthrough.
    [ "$_decision" = "null" ] && _decision=""
    log "review decision for PR #$PR_NUM: ${_decision:-<empty>}"

    case "$_decision" in
        CHANGES_REQUESTED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$_REWORK_LABEL"
            ;;
        APPROVED)
            # APPROVED path is unchanged — the agent applies needs-qa itself.
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
        *)
            # Empty / REVIEW_REQUIRED / COMMENTED — fall through to belt-and-braces.
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
    esac

    # Belt-and-braces: if agent forgot to apply a decision label, default to rework
    # (workflow-resolved) so the PR doesn't silently disappear from the pipeline.
    if ! backend_pr_has_any_label "$REPO" "$PR_NUM" \
            "$LOOP_LABEL_NEEDS_QA" "$LOOP_LABEL_DEPRECATED_READY_FOR_QA" \
            "$_REWORK_LABEL" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" \
            blocked 'done'; then
        log "WARN: PR #$PR_NUM has no decision label after review agent — defaulting to '${_REWORK_LABEL}'"
        backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED"
        backend_add_label "$REPO" "$PR_NUM" "$_REWORK_LABEL"
    fi
else
    n=$(retry_incr)
    log "review agent failed for PR #$PR_NUM (attempt $n/$MAX_RETRIES)"
    bounty_report "review_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=reviewer project="$SLUG" pr_num="$PR_NUM" detail="attempt ${n}/${MAX_RETRIES}" || true
    if [ "$n" -ge "$MAX_RETRIES" ]; then
        backend_remove_label "$REPO" "$PR_NUM" in-review
        backend_remove_label "$REPO" "$PR_NUM" "$_REWORK_LABEL"
        backend_add_label "$REPO" "$PR_NUM" "$_REWORK_LABEL"
        # Post only a short marker — never the agent log/prompt, which contains
        # internal pipeline instructions that must not become public.
        backend_comment_pr "$REPO" "$PR_NUM" \
            "Automated review failed ${MAX_RETRIES} times. Needs human eyes. Operator: see ${LOG_FILE} for the agent transcript." \
            2>/dev/null || true
        loop_notify "❌ [$SLUG] PR#$PR_NUM review failed: agent failed after $MAX_RETRIES attempts"
    else
        backend_remove_label "$REPO" "$PR_NUM" in-review
    fi
    exit 1
fi
