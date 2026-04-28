#!/usr/bin/env bash
# dev-rework-handler.sh — handles one loop.dev_rework event.
# Deprecated name: prefer scripts/reviser.sh
#
# Fires when a PR is labeled 'changes-requested' by the review-handler.
# Checks out the existing PR branch, reads the reviewer feedback, and
# asks the orchestrator to address it. On success, swaps the PR label
# back to 'review-pending' so review-handler re-evaluates.
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
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"

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
    SOURCE_LABEL="qa-fail"
else
    SOURCE_LABEL="changes-requested"
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
}

if [ "$retries" -ge "$MAX_RETRIES" ]; then
    log "PR #$PR_NUM rework failed ${retries}x — labeling blocked"
    backend_remove_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
    backend_remove_label "$REPO" "$PR_NUM" in-rework
    backend_add_label "$REPO" "$PR_NUM" blocked
    backend_comment_pr "$REPO" "$PR_NUM" \
        "Automated rework failed ${MAX_RETRIES} times. Needs human eyes."
    _block_linked_issue
    exit 0
fi

log "rework: slug=$SLUG repo=$REPO pr=#$PR_NUM attempt=$((retries + 1))/$MAX_RETRIES"
bounty_report "rework_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" pr_num="$PR_NUM" || true
loop_notify "▶️ [$SLUG] PR#$PR_NUM dev-rework starting"
_update_issue_rework_count "$((retries + 1))"

backend_remove_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
backend_add_label "$REPO" "$PR_NUM" in-rework

PR_BRANCH=$(backend_pr_view "$REPO" "$PR_NUM" --json headRefName --jq .headRefName 2>/dev/null || echo "")
[ -n "$PR_BRANCH" ] || { log "ERROR: couldn't fetch PR branch"; exit 1; }

WORKTREE_ROOT="/tmp/loop-rework-${SLUG}-${PR_NUM}"
if [ -d "$WORKTREE_ROOT" ]; then
    git -C "$ROOT" worktree remove "$WORKTREE_ROOT" --force 2>/dev/null || rm -rf "$WORKTREE_ROOT"
fi
git -C "$ROOT" fetch origin "$PR_BRANCH" "$DEFAULT_BRANCH" --quiet 2>&1 | tee -a "$LOG_FILE" || true
if ! git -C "$ROOT" worktree add "$WORKTREE_ROOT" "origin/$PR_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: failed to create worktree at $WORKTREE_ROOT for branch $PR_BRANCH"
    backend_remove_label "$REPO" "$PR_NUM" in-rework
    backend_add_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
    exit 1
fi
log "worktree ready: $WORKTREE_ROOT (branch $PR_BRANCH)"

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

# For qa-fail context, fetch QA failure details from PR comments.
QA_FAILURE_DETAILS=""
if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
    QA_FAILURE_DETAILS=$(gh pr view "$PR_NUM" --repo "$REPO" --json comments \
        --jq '[.comments[] | select(.body | test("QA|qa-fail|qa_fail"; "i"))] | last | .body // ""' \
        2>/dev/null || echo "")
    if [ -z "$QA_FAILURE_DETAILS" ]; then
        QA_FAILURE_DETAILS="No QA failure comment found — check loop-qa-handler.log for details."
    fi
    log "qa-fail details: $QA_FAILURE_DETAILS"
fi

# Resolve workflow-specific labels for this project (default vs current).
REVIEW_LABEL=$(loop_stage_trigger "$SLUG" review pr 2>/dev/null || echo review-pending)

if [ "$REWORK_CONTEXT" = "qa-fail" ]; then
    _REWORK_TRIGGER="a QA failure"
    _STEP2="2. This rework was triggered by a QA FAILURE. Fix the issues reported below.
   QA failure details:
   ---
   ${QA_FAILURE_DETAILS}
   ---
   If no details are shown, run: gh pr view ${PR_NUM} --repo ${REPO} --json comments
   and look for comments containing QA failure output.
   Check for merge conflicts too:
   gh pr view ${PR_NUM} --repo ${REPO} --json mergeable,mergeStateStatus
   - If mergeable=CONFLICTING or mergeStateStatus=DIRTY: rebase first (see below), then fix QA issues."
    _STEP7="   gh pr comment ${PR_NUM} --repo ${REPO} --body 'Fixed QA failure: <summary of what was fixed>'"
else
    _REWORK_TRIGGER="reviewer feedback"
    _STEP2="2. Check PR state details -- the trigger could be reviewer feedback OR a merge conflict:
   gh pr view ${PR_NUM} --repo ${REPO} --json body,reviews,comments,mergeable,mergeStateStatus
   - If mergeable=CONFLICTING or mergeStateStatus=DIRTY: rebase onto origin/${DEFAULT_BRANCH} and resolve conflicts. Use 'git fetch origin && git rebase origin/${DEFAULT_BRANCH}', resolve each conflicted file, 'git add' resolved files, 'git rebase --continue', then 'git push --force-with-lease origin ${PR_BRANCH}'. Skip to step 6.
   - Otherwise: focus on the most recent review with state REQUEST_CHANGES and its inline comments."
    _STEP7="   gh pr comment ${PR_NUM} --repo ${REPO} --body 'Addressed review feedback: <summary>'"
fi

if [ -n "$DEV_VALIDATION_CMD" ]; then
    _VALIDATION_STEP="4. Run validation: ${DEV_VALIDATION_CMD//\{project_root\}/$ROOT}"
else
    _VALIDATION_STEP=""
fi

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
   - If state=MERGED: the PR already merged. Remove label 'in-rework', add comment explaining PR is already merged, and stop.
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
   gh pr edit ${PR_NUM} --repo ${REPO} --remove-label in-rework --remove-label needs-rework --remove-label changes-requested --remove-label qa-fail --remove-label qa-failed --add-label ${REVIEW_LABEL}

IMPORTANT: The PR MUST end this run with label '${REVIEW_LABEL}' (or 'needs-clarification'/'blocked' if appropriate). Verify with:
   gh pr view ${PR_NUM} --repo ${REPO} --json labels

If the feedback is unclear or requires architectural input, add label 'needs-clarification' and comment on the PR instead of guessing.
${_BACKEND_CLI_NOTE}
EOF
TASK_PROMPT=$(cat "$_PROMPT_FILE")
rm -f "$_PROMPT_FILE"

cleanup_worktree() {
    git -C "$ROOT" worktree remove "$WORKTREE_ROOT" --force 2>/dev/null \
        || rm -rf "$WORKTREE_ROOT"
    git -C "$ROOT" worktree prune 2>/dev/null || true
}

if loop_run_agent "$TASK_PROMPT" "$WORKTREE_ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    log "rework agent succeeded for PR #$PR_NUM"
    bounty_report "rework_done" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "✅ [$SLUG] PR#$PR_NUM dev-rework done"
    retry_clear
    # Strip every label from the prior stage (rework entry triggers + qa-fail
    # entry trigger) so the PR doesn't sit multi-labeled and bounce back into
    # rework on the next scanner tick. Closes loop#15.
    backend_remove_label "$REPO" "$PR_NUM" in-rework needs-rework changes-requested qa-fail qa-failed
    # Belt-and-braces: if agent forgot step 8, ensure PR has a progression label.
    if ! backend_pr_has_any_label "$REPO" "$PR_NUM" review-pending needs-review needs-clarification blocked 'done'; then
        log "WARN: PR #$PR_NUM has no progression label after rework agent — adding '${REVIEW_LABEL}'"
        backend_add_label "$REPO" "$PR_NUM" "$REVIEW_LABEL"
    fi
    cleanup_worktree
else
    n=$(retry_incr)
    log "rework agent failed for PR #$PR_NUM (attempt $n/$MAX_RETRIES)"
    bounty_report "rework_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" pr_num="$PR_NUM" detail="attempt ${n}/${MAX_RETRIES}" || true
    if [ "$n" -ge "$MAX_RETRIES" ]; then
        backend_remove_label "$REPO" "$PR_NUM" in-rework
        backend_add_label "$REPO" "$PR_NUM" blocked
        backend_comment_pr "$REPO" "$PR_NUM" \
            "Automated rework failed ${MAX_RETRIES} times. Marking blocked for human review. Operator: see ${LOG_FILE} for the agent transcript."
        loop_notify "❌ [$SLUG] PR#$PR_NUM dev-rework failed: agent failed after $MAX_RETRIES attempts"
    else
        backend_remove_label "$REPO" "$PR_NUM" in-rework
        backend_add_label "$REPO" "$PR_NUM" "$SOURCE_LABEL"
    fi
    cleanup_worktree
    exit 1
fi
