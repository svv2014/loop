#!/usr/bin/env bash
# dev-rework-handler.sh — handles one loop.dev_rework event.
# Deprecated name: prefer scripts/reviser.sh
#
# Fires when a PR is labeled with the rework trigger by the review-handler.
# Checks out the existing PR branch, reads the reviewer feedback, and
# asks the orchestrator to address it. On success, swaps the PR label
# back to the workflow's review-trigger so review-handler re-evaluates.
#
# Event payload: {"slug","repo","pr_number","pr_title","pr_url"}

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
# shellcheck source=../lib/progress.sh
source "$LOOP_ROOT/lib/progress.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/cli-hint.sh
source "$LOOP_ROOT/lib/cli-hint.sh"
# shellcheck source=../lib/worktree.sh
source "$LOOP_ROOT/lib/worktree.sh"
# shellcheck source=../lib/comments.sh
source "$LOOP_ROOT/lib/comments.sh"
# shellcheck source=../lib/prompt-untrust.sh
source "$LOOP_ROOT/lib/prompt-untrust.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-dev-rework-handler.log"
MAX_RETRIES=2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [dev-rework-handler] $*" | tee -a "$LOG_FILE"; }

SLUG="${LOOP_SLUG:-}"
PR_NUM="${LOOP_PR_NUMBER:-}"
PR_TITLE="${LOOP_PR_TITLE:-}"
PR_URL="${LOOP_PR_URL:-}"
REWORK_CONTEXT="${LOOP_REWORK_CONTEXT:-}"

if [ -z "$SLUG" ] || [ -z "$PR_NUM" ]; then
    EVENT_JSON="${LOOP_EVENT_JSON:-}"
    if [ -z "$EVENT_JSON" ] && [ ! -t 0 ]; then
        EVENT_JSON=$(cat)
    fi
    if [ -n "$EVENT_JSON" ]; then
        SLUG=$(echo "$EVENT_JSON"           | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('slug',''))")
        PR_NUM=$(echo "$EVENT_JSON"         | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_number',''))")
        PR_TITLE=$(echo "$EVENT_JSON"       | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_title',''))")
        PR_URL=$(echo "$EVENT_JSON"         | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('pr_url',''))")
        REWORK_CONTEXT=$(echo "$EVENT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',d).get('rework_context',''))")
    fi
fi

# SOURCE_LABEL is the label that triggered this rework (to remove on start, restore on retry).
if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
    SOURCE_LABEL="$LOOP_LABEL_QA_FAIL"
else
    SOURCE_LABEL="$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED"
fi

[ -n "$SLUG" ] && [ -n "$PR_NUM" ] \
    || { log "ERROR: missing slug or pr_number"; exit 2; }

loop_load_project "$SLUG" || { log "ERROR: unknown slug '$SLUG'"; exit 2; }
loop_load_backend

# PR-scoped lock — each PR gets its own worktree so multiple reworks can run in parallel.
source "$LOOP_ROOT/lib/lock.sh"
loop_acquire_lock "${SLUG}-pr-${PR_NUM}" || { log "ERROR: couldn't acquire lock for ${SLUG}-pr-${PR_NUM} within 1hr — exiting"; exit 1; }
log "acquired PR lock for ${SLUG}-pr-${PR_NUM}"

RETRY_FILE="/tmp/loop-rework-retries-${SLUG}-${PR_NUM}-${REWORK_CONTEXT:-cr}"
retry_count() { [ -f "$RETRY_FILE" ] && cat "$RETRY_FILE" || echo 0; }
retry_incr()  { local n; n=$(( $(retry_count) + 1 )); echo "$n" > "$RETRY_FILE"; echo "$n"; }
retry_clear() { rm -f "$RETRY_FILE"; }

retries=$(retry_count)

# Resolve linked issue number from PR body ("Closes #N")
LINKED_ISSUE=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null \
    | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")

_update_issue_rework_count() {
    local attempt="$1"
    [ -z "$LINKED_ISSUE" ] && return 0
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    local context_label; context_label=$( [ "$REWORK_CONTEXT" = "qa-fail" ] && echo "QA failure" || echo "reviewer feedback" )
    backend_comment_issue "$REPO" "$LINKED_ISSUE" \
        "🔁 Rework attempt ${attempt}/${MAX_RETRIES} started (${context_label}) — PR #${PR_NUM} (${ts})" \
        2>/dev/null || true
}

_block_linked_issue() {
    [ -z "$LINKED_ISSUE" ] && return 0
    backend_add_label "$REPO" "$LINKED_ISSUE" blocked 2>/dev/null || true
    backend_comment_issue "$REPO" "$LINKED_ISSUE" \
        "🚫 Blocked: automated rework failed ${MAX_RETRIES} times on PR #${PR_NUM}. Needs human review." \
        2>/dev/null || true
    loop_notify_human_required "$SLUG" "$LINKED_ISSUE" blocked "Rework failed ${MAX_RETRIES}x on PR #${PR_NUM}"
}

SENIOR_ESCALATION_MARKER="Escalating to senior-dev for one final attempt"

_is_senior_escalated() {
    [ -z "$LINKED_ISSUE" ] && return 1
    local count
    count=$(gh issue view "$LINKED_ISSUE" --repo "$REPO" --json comments \
        --jq "[.comments[] | select(.body | contains(\"${SENIOR_ESCALATION_MARKER}\"))] | length" \
        2>/dev/null || echo "0")
    [ "${count:-0}" -gt 0 ]
}

_escalate_to_senior() {
    [ -z "$LINKED_ISSUE" ] && return 0
    backend_comment_issue "$REPO" "$LINKED_ISSUE" \
        "Dev rework exhausted ${MAX_RETRIES} attempts. Escalating to senior-dev for one final attempt." \
        2>/dev/null || true
    backend_add_label "$REPO" "$LINKED_ISSUE" senior-dev 2>/dev/null || true
}

_block_linked_issue_senior_failed() {
    [ -z "$LINKED_ISSUE" ] && return 0
    backend_add_label "$REPO" "$LINKED_ISSUE" blocked 2>/dev/null || true
    backend_comment_issue "$REPO" "$LINKED_ISSUE" \
        "Senior-dev attempt also failed. Marking blocked for human review." \
        2>/dev/null || true
    loop_notify_human_required "$SLUG" "$LINKED_ISSUE" blocked "Senior-dev escalation also failed on PR #${PR_NUM}"
}

if [ "$retries" -ge "$MAX_RETRIES" ]; then
    log "PR #$PR_NUM rework failed ${retries}x — checking escalation path"
    backend_remove_label "$REPO" "$PR_NUM" "$SOURCE_LABEL" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_IN_REWORK" 2>/dev/null || true
    if [ -n "$LINKED_ISSUE" ] && ! _is_senior_escalated; then
        log "escalating issue #$LINKED_ISSUE to senior-dev"
        _escalate_to_senior
        backend_comment_pr "$REPO" "$PR_NUM" \
            "Dev rework exhausted ${MAX_RETRIES} attempts. Escalating to senior-dev for one final attempt." \
            2>/dev/null || true
        loop_notify "⬆️ [$SLUG] PR#$PR_NUM dev-rework exhausted — escalated issue #$LINKED_ISSUE to senior-dev"
    else
        log "senior-dev escalation already attempted — labeling blocked"
        backend_add_label "$REPO" "$PR_NUM" blocked
        backend_comment_pr "$REPO" "$PR_NUM" \
            "Senior-dev attempt also failed. Marking blocked for human review. Operator: see ${LOG_FILE} for the agent transcript." \
            2>/dev/null || true
        _block_linked_issue_senior_failed
        loop_notify "❌ [$SLUG] PR#$PR_NUM dev-rework blocked after senior-dev escalation also failed"
    fi
    exit 0
fi

log "rework: slug=$SLUG repo=$REPO pr=#$PR_NUM attempt=$((retries + 1))/$MAX_RETRIES"
bounty_report "rework_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" pr_num="$PR_NUM" || true
loop_notify "▶️ [$SLUG] PR#$PR_NUM dev-rework starting"
_update_issue_rework_count "$((retries + 1))"

backend_remove_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
# Strip stale needs-qa (and its deprecated alias / qa-pass) so the PR never
# carries both needs-qa and a rework label simultaneously — which would make
# the scanner emit conflicting pr_qa + dev_rework events on the next tick.
if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_NEEDS_QA" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_READY_FOR_QA" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_QA_PASS" 2>/dev/null || true
fi
backend_add_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_IN_REWORK"

PR_BRANCH=$(backend_pr_view "$REPO" "$PR_NUM" --json headRefName --jq .headRefName 2>/dev/null || echo "")
[ -n "$PR_BRANCH" ] || { log "ERROR: couldn't fetch PR branch"; exit 1; }

WORKTREE_ROOT="/tmp/loop-rework-${SLUG}-${PR_NUM}"
if [ -d "$WORKTREE_ROOT" ]; then
    git -C "$ROOT" worktree remove "$WORKTREE_ROOT" --force 2>/dev/null || rm -rf "$WORKTREE_ROOT"
fi
git -C "$ROOT" fetch origin "$PR_BRANCH" "$DEFAULT_BRANCH" --quiet 2>&1 | tee -a "$LOG_FILE" || true
if ! git -C "$ROOT" worktree add "$WORKTREE_ROOT" "origin/$PR_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: failed to create worktree at $WORKTREE_ROOT for branch $PR_BRANCH"
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_IN_REWORK"
    backend_add_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
    exit 1
fi
log "worktree ready: $WORKTREE_ROOT (branch $PR_BRANCH)"

# Symlink any project-declared extra paths (gitignored runtime data, models)
# from the primary checkout into the worktree.
loop_link_worktree_extras "$ROOT" "$WORKTREE_ROOT" 2>&1 | tee -a "$LOG_FILE"

# System invariant: rework agent must never run on a stale base. Always rebase
# the branch onto current origin/<default> so the agent sees up-to-date world.
# Clean rebase = silent; conflicting rebase = abort and let agent address conflicts
# via the prompt instructions below.
REBASE_CONFLICTS=""
if ! git -C "$WORKTREE_ROOT" rebase "origin/$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    REBASE_CONFLICTS=$(git -C "$WORKTREE_ROOT" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    git -C "$WORKTREE_ROOT" rebase --abort 2>/dev/null || true
    log "rebase onto origin/$DEFAULT_BRANCH had conflicts: ${REBASE_CONFLICTS:-(unknown)}"
else
    # Clean rebase — push the freshened branch so CI re-runs against new base.
    if git -C "$WORKTREE_ROOT" push --force-with-lease origin "$PR_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        log "rebased $PR_BRANCH onto origin/$DEFAULT_BRANCH and force-pushed"
    else
        log "WARN: rebase succeeded locally but push failed — agent will retry"
    fi
fi

# For qa-fail context, fetch QA failure details from trusted PR comments only.
QA_FAILURE_DETAILS=""
if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
    # Use comments_fetch_trusted so external comment bodies never enter the prompt.
    _TRUSTED_COMMENTS=$(comments_fetch_trusted "$REPO" "$PR_NUM" 2>/dev/null || echo "")
    if [ -n "$_TRUSTED_COMMENTS" ]; then
        while IFS=$'\t' read -r _login _assoc _body; do
            case "$_body" in
                *QA*|*qa-fail*|*qa_fail*)
                    QA_FAILURE_DETAILS="$_body"
                    break
                    ;;
            esac
        done <<< "$_TRUSTED_COMMENTS"
    fi
    if [ -z "$QA_FAILURE_DETAILS" ]; then
        QA_FAILURE_DETAILS="No trusted QA failure comment found — check loop-qa-handler.log for details."
    fi
    log "qa-fail details (trusted): $QA_FAILURE_DETAILS"
    QA_FAILURE_DETAILS=$(printf '%s' "$QA_FAILURE_DETAILS" | prompt_untrust_wrap review_feedback)
fi

# Resolve workflow-specific labels for this project (default vs current).
_REVIEW_LABEL=$(loop_label_for "$SLUG" "needs-review")
_REWORK_LABEL=$(loop_label_for "$SLUG" "needs-rework")
_QA_LABEL=$(loop_label_for "$SLUG" "needs-qa")
_QA_PASS_LABEL=$(loop_label_for "$SLUG" "qa-pass")
_QA_FAIL_LABEL=$(loop_label_for "$SLUG" "qa-fail")

_FULL_PR_DIAGNOSTICS="Read the PR's full state before deciding what to fix. The trigger could be ANY of: failing CI, merge conflict, reviewer feedback, QA failure. Always check all four.

   a. Mergeability:
      gh pr view ${PR_NUM} --repo ${REPO} --json mergeable,mergeStateStatus
      If mergeable=CONFLICTING or mergeStateStatus=DIRTY: rebase first (see below) before anything else.${REBASE_CONFLICTS:+

      AUTO-REBASE ALREADY ATTEMPTED AND ABORTED — these files conflicted:
        ${REBASE_CONFLICTS}
      Re-run \`git rebase origin/${DEFAULT_BRANCH}\` and resolve each file
      with intent (read both sides, integrate semantically — do not blindly
      \`--theirs\` or \`--ours\`). Then \`git add\` resolved files,
      \`git rebase --continue\`, and \`git push --force-with-lease origin ${PR_BRANCH}\`.}

   b. CI check status:
      gh pr view ${PR_NUM} --repo ${REPO} --json statusCheckRollup
      For EACH check whose conclusion is FAILURE, fetch the actual log:
        gh run view <run-id> --repo ${REPO} --log-failed | tail -120
      where <run-id> is the run-id surfaced by statusCheckRollup. The log shows
      exactly which file/line failed (lint rule, type error, build error,
      test assertion). DO NOT guess what's wrong — read the log.

   c. Review feedback:
      gh pr view ${PR_NUM} --repo ${REPO} --json reviews,comments
      Focus on the most recent review with state=REQUEST_CHANGES, plus its
      inline comments and general comments. Address every concrete point.

   d. PR comments (e.g. QA failure summaries):
      Same json fetch above; look for comments containing 'qa-fail', 'QA',
      lint output, build output, or test failures.

   Now you have the full picture: rebase if needed → fix each CI failure
   using the actual log output → address review feedback → run validation
   locally before committing."

if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
    _REWORK_TRIGGER="a QA failure"
    _STEP2="2. ${_FULL_PR_DIAGNOSTICS}

   QA failure details captured at dispatch (use as a starting point; still
   re-read PR state above):
   ---
   ${QA_FAILURE_DETAILS}
   ---"
    _STEP7="   gh pr comment ${PR_NUM} --repo ${REPO} --body 'Fixed QA failure: <summary of what was fixed>'"
else
    _REWORK_TRIGGER="reviewer feedback or CI failure"
    _STEP2="2. ${_FULL_PR_DIAGNOSTICS}"
    _STEP7="   gh pr comment ${PR_NUM} --repo ${REPO} --body 'Addressed feedback / fixed CI: <summary>'"
fi

_VALIDATION_STEP="4. Validate locally before committing — match CI exactly. Discover what CI runs by reading the project itself:
   a. Inspect .github/workflows/*.yml — list every \`run:\` step in jobs triggered on pull_request / push.
   b. Inspect package.json (scripts), Makefile (targets), pyproject.toml ([tool.*]), .pre-commit-config.yaml for the actual commands.
   c. Run those commands locally in this worktree, in dependency order (lint → typecheck → tests → build). Iterate until ALL pass.
   d. If deps are missing (node_modules, build venv): install, then run. Some gitignored paths may be pre-symlinked — check before installing.${DEV_VALIDATION_CMD:+ Operator-provided hint (run this in addition to the discovery above): ${DEV_VALIDATION_CMD//\{project_root\}/$ROOT}}
   Push only after every CI-equivalent check passes locally."
_BACKEND_CLI_NOTE=$(backend_cli_note)

_PROMPT_FILE=$(mktemp /tmp/rework-prompt-XXXXXX.txt)
cat > "$_PROMPT_FILE" <<EOF
You are the Senior Developer for ${NAME} (slug: ${SLUG}), reworking a PR after ${_REWORK_TRIGGER}.
Working directory: ${WORKTREE_ROOT}
Repo: ${REPO}
PR: #${PR_NUM} -- ${PR_TITLE}
URL: ${PR_URL}
Branch: ${PR_BRANCH}

First, READ ${WORKTREE_ROOT}/CLAUDE.md for full project context.
If CLAUDE.md is missing, proceed with best judgment and note the absence in your PR comment.

Your job -- in sequence:

0. Check PR state before doing anything:
   gh pr view ${PR_NUM} --repo ${REPO} --json state,merged
   - If state=MERGED: the PR already merged. Remove label '${LOOP_LABEL_DEPRECATED_IN_REWORK}', add comment explaining PR is already merged, and stop.
   - If state=CLOSED and merged=false: label the PR 'blocked', comment explaining it was closed without merging, and stop.
   - If state=OPEN: continue to step 1.

1. cd ${WORKTREE_ROOT}  (already on ${PR_BRANCH})
${_STEP2}
3. Address every point of feedback in code. Follow CLAUDE.md conventions.
${_VALIDATION_STEP}
5. If there are new changes to commit: git commit -m '[${COMMIT_PREFIX}-rework-${PR_NUM}] <short description of what you addressed>'
   If all feedback was already addressed in prior commits and there are no staged changes, skip this step.
6. Push the branch: git push origin ${PR_BRANCH}
   (or git push --force-with-lease origin ${PR_BRANCH} if a rebase was performed)
7. Post a PR comment summarizing what you changed in response:
${_STEP7}
8. Swap labels -- this is MANDATORY to signal success to the pipeline:
   gh pr edit ${PR_NUM} --repo ${REPO} --remove-label ${LOOP_LABEL_DEPRECATED_IN_REWORK} --remove-label ${_REWORK_LABEL} --remove-label ${_QA_FAIL_LABEL} --add-label ${_REVIEW_LABEL}

IMPORTANT: The PR MUST end this run with label '${_REVIEW_LABEL}' (or 'needs-clarification'/'blocked' if appropriate). Verify with:
   gh pr view ${PR_NUM} --repo ${REPO} --json labels

If the feedback is unclear or requires architectural input, add label 'needs-clarification' and comment on the PR instead of guessing.
${_BACKEND_CLI_NOTE}
$(loop_cli_hint)
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

cleanup_worktree() {
    git -C "$ROOT" worktree remove "$WORKTREE_ROOT" --force 2>/dev/null \
        || rm -rf "$WORKTREE_ROOT"
    git -C "$ROOT" worktree prune 2>/dev/null || true
}

_AGENT_RC=0
_REWORK_LOG_START=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
progress_start dev_rework
if ! loop_run_agent "$TASK_PROMPT" "$WORKTREE_ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    _AGENT_RC=1
fi
progress_stop
_rework_tail=$(tail -n +"$((_REWORK_LOG_START + 1))" "$LOG_FILE" 2>/dev/null | tail -200)

# Post-agent DIRTY check: if the pre-agent rebase detected conflicts, verify
# the agent actually resolved them.  One attempt only — if the branch is still
# DIRTY against origin/<default_branch>, escalate immediately (blocked) rather
# than retrying; retries cannot fix an unresolved merge conflict.
_POST_DIRTY=false
_POST_AGENT_CONFLICTS=""
if [ -n "$REBASE_CONFLICTS" ]; then
    git -C "$WORKTREE_ROOT" fetch origin "$DEFAULT_BRANCH" --quiet 2>&1 | tee -a "$LOG_FILE" || true
    if ! git -C "$WORKTREE_ROOT" rebase "origin/$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        _POST_DIRTY=true
        _POST_AGENT_CONFLICTS=$(git -C "$WORKTREE_ROOT" diff --name-only --diff-filter=U 2>/dev/null \
            | tr '\n' ' ')
        _POST_AGENT_CONFLICTS="${_POST_AGENT_CONFLICTS% }"
        git -C "$WORKTREE_ROOT" rebase --abort 2>/dev/null || true
        log "post-agent rebase still conflicts: ${_POST_AGENT_CONFLICTS:-(unknown)}"
    else
        git -C "$WORKTREE_ROOT" push --force-with-lease origin "$PR_BRANCH" 2>&1 | tee -a "$LOG_FILE" \
            || log "WARN: post-agent clean rebase push failed — continuing"
        log "post-agent rebase clean — agent resolved conflicts, pushed $PR_BRANCH"
    fi
fi

if [ "$_POST_DIRTY" = "true" ]; then
    log "PR #$PR_NUM still DIRTY after agent — escalating as blocked"
    backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_IN_REWORK" 2>/dev/null || true
    backend_add_label "$REPO" "$PR_NUM" blocked 2>/dev/null || true
    _BLOCK_MARKER="<!-- loop:rework_blocked -->"
    _ALREADY_BLOCKED=$(gh pr view "$PR_NUM" --repo "$REPO" --json comments \
        --jq "[.comments[] | select(.body | contains(\"${_BLOCK_MARKER}\"))] | length" \
        2>/dev/null || echo "0")
    if [ "${_ALREADY_BLOCKED:-0}" = "0" ]; then
        _CONFLICT_DISPLAY=$(echo "${_POST_AGENT_CONFLICTS:-(unknown)}" | tr ' ' '\n')
        _BLOCK_BODY=$(printf '%s\n%s\n\n```\n%s\n```' \
            "$_BLOCK_MARKER" \
            "Rework blocked: rebase conflict unresolved after agent attempt." \
            "$_CONFLICT_DISPLAY")
        if [ -n "$LINKED_ISSUE" ]; then
            _BLOCK_BODY=$(printf '%s\nParent: #%s' "$_BLOCK_BODY" "$LINKED_ISSUE")
        fi
        gh pr comment "$PR_NUM" --repo "$REPO" --body "$_BLOCK_BODY" 2>/dev/null || true
    fi
    _rework_blocked_diag="$(bounty_truncate_detail "$_rework_tail")"
    bounty_report "rework_blocked" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" \
        pr_num="$PR_NUM" detail="${_rework_blocked_diag:+${_rework_blocked_diag} | }rebase-conflict files=${_POST_AGENT_CONFLICTS}" || true
    loop_notify "🚫 [$SLUG] PR#$PR_NUM rework blocked — rebase conflict unresolved"
    cleanup_worktree
    exit 0
fi

if [ "$_AGENT_RC" -eq 0 ]; then
    log "rework agent succeeded for PR #$PR_NUM"
    bounty_report "rework_done" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "✅ [$SLUG] PR#$PR_NUM dev-rework done"
    retry_clear
    # Strip every label from the prior stage (rework entry triggers + qa-fail
    # entry trigger) so the PR doesn't sit multi-labeled and bounce back into
    # rework on the next scanner tick. Closes loop#15.
    backend_remove_label "$REPO" "$PR_NUM" \
        "$LOOP_LABEL_DEPRECATED_IN_REWORK" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" \
        "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" "$LOOP_LABEL_QA_FAIL" qa-failed
    # Belt-and-braces: if agent forgot step 8, ensure PR has a progression label.
    if ! backend_pr_has_any_label "$REPO" "$PR_NUM" \
            "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING" "$LOOP_LABEL_NEEDS_REVIEW" \
            needs-clarification blocked 'done'; then
        log "WARN: PR #$PR_NUM has no progression label after rework agent — adding '${_REVIEW_LABEL}'"
        backend_add_label "$REPO" "$PR_NUM" "$_REVIEW_LABEL"
    fi
    cleanup_worktree
else
    n=$(retry_incr)
    log "rework agent failed for PR #$PR_NUM (attempt $n/$MAX_RETRIES)"
    # Best-effort: surface unmet AC checkboxes from reviewer feedback in the rework log.
    _unmet_ac=$(printf '%s' "$_rework_tail" | grep -E '^\s*- \[ \]' | head -3 | tr '\n' ' ' 2>/dev/null || true)
    _rework_failed_diag="$(bounty_truncate_detail "${_unmet_ac:-$_rework_tail}")"
    bounty_report "rework_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" pr_num="$PR_NUM" detail="${_rework_failed_diag:+${_rework_failed_diag} | }attempt ${n}/${MAX_RETRIES}" || true
    if [ "$n" -ge "$MAX_RETRIES" ]; then
        backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_IN_REWORK"
        if [ -n "$LINKED_ISSUE" ] && ! _is_senior_escalated; then
            log "escalating issue #$LINKED_ISSUE to senior-dev after $MAX_RETRIES failed rework attempts"
            _escalate_to_senior
            # Post only a short marker to the PR — never the agent log/prompt, which
            # contains internal pipeline instructions that should not be public.
            backend_comment_pr "$REPO" "$PR_NUM" \
                "Dev rework exhausted ${MAX_RETRIES} attempts. Escalating to senior-dev for one final attempt." \
                2>/dev/null || true
            loop_notify "⬆️ [$SLUG] PR#$PR_NUM dev-rework exhausted — escalated issue #$LINKED_ISSUE to senior-dev"
        else
            backend_add_label "$REPO" "$PR_NUM" blocked
            backend_comment_pr "$REPO" "$PR_NUM" \
                "Senior-dev attempt also failed. Marking blocked for human review. Operator: see ${LOG_FILE} for the agent transcript." \
                2>/dev/null || true
            _block_linked_issue_senior_failed
            loop_notify "❌ [$SLUG] PR#$PR_NUM dev-rework blocked after senior-dev escalation also failed"
        fi
    else
        backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_IN_REWORK"
        backend_add_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
    fi
    cleanup_worktree
    exit 1
fi
