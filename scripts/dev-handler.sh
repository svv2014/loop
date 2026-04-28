#!/usr/bin/env bash
# dev-handler.sh — handles one loop.dev_issue event.
# Deprecated name: prefer scripts/builder.sh
#
# Event payload (read from $LOOP_EVENT_JSON env var or stdin):
#   {"slug","repo","issue_number","issue_title","issue_url"}

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

LOG_FILE="${LOOP_LOG_DIR}/loop-dev-handler.log"
MAX_RETRIES=3

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [dev-handler] $*" | tee -a "$LOG_FILE"; }

# Read event fields — prefer explicit env vars (set by router), fall back to JSON stdin/env.
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
    || { log "ERROR: missing slug or issue_number in payload"; exit 2; }

loop_load_project "$SLUG" || { log "ERROR: unknown slug '$SLUG'"; exit 2; }
loop_load_backend

# Issue-scoped lock — multiple issues in the same project can develop in parallel.
# Each issue already gets its own worktree, so no shared state to protect.
source "$LOOP_ROOT/lib/lock.sh"
loop_acquire_lock "${SLUG}-issue-${ISSUE_NUM}" || { log "ERROR: couldn't acquire lock for ${SLUG}-issue-${ISSUE_NUM} within 1hr — exiting"; exit 1; }
log "acquired issue lock for ${SLUG}-issue-${ISSUE_NUM}"

RETRY_FILE="/tmp/loop-dev-retries-${SLUG}-${ISSUE_NUM}"
retry_count() { [ -f "$RETRY_FILE" ] && cat "$RETRY_FILE" || echo 0; }
retry_incr()  { local n; n=$(( $(retry_count) + 1 )); echo "$n" > "$RETRY_FILE"; echo "$n"; }
retry_clear() { rm -f "$RETRY_FILE"; }

retries=$(retry_count)
if [ "$retries" -ge "$MAX_RETRIES" ]; then
    log "issue #$ISSUE_NUM already failed ${retries}x — labeling blocked"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    backend_add_label "$REPO" "$ISSUE_NUM" blocked
    exit 0
fi

log "dev handler: slug=$SLUG repo=$REPO issue=#$ISSUE_NUM attempt=$((retries + 1))/$MAX_RETRIES"
bounty_report "dev_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" issue_num="$ISSUE_NUM" || true
loop_notify "▶️ [$SLUG] #$ISSUE_NUM dev starting"

# Fetch issue body
ISSUE_BODY=$(backend_issue_view "$REPO" "$ISSUE_NUM" --json body --jq .body 2>/dev/null || echo "")

# Claim the issue
backend_add_label "$REPO" "$ISSUE_NUM" in-progress

# Isolated worktree per issue — prevents parallel dev-handlers from stomping on
# each other's working tree (observed bug: files from branch A leaked into
# branch B's PR when two handlers ran concurrently).
WORKTREE_ROOT="/tmp/loop-worktree-${SLUG}-${ISSUE_NUM}"
if [ -d "$WORKTREE_ROOT" ]; then
    git -C "$ROOT" worktree remove "$WORKTREE_ROOT" --force 2>/dev/null || rm -rf "$WORKTREE_ROOT"
fi
git -C "$ROOT" fetch origin "$DEFAULT_BRANCH" --quiet 2>&1 | tee -a "$LOG_FILE" || true
if ! git -C "$ROOT" worktree add "$WORKTREE_ROOT" "origin/$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: failed to create worktree at $WORKTREE_ROOT"
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    exit 1
fi
log "worktree ready: $WORKTREE_ROOT (isolated from other handlers)"

# Resolve workflow-specific labels for this project so the agent prompt + the
# belt-and-braces apply the right names per the project's active workflow
# (e.g. needs-review on default, review-pending on current).
REVIEW_LABEL=$(loop_stage_trigger "$SLUG" review pr 2>/dev/null || echo review-pending)

TASK_PROMPT=$(cat <<EOF
You are the Senior Developer for ${NAME} (slug: ${SLUG}).
Working directory: ${WORKTREE_ROOT}
Repo: ${REPO}
Default branch: ${DEFAULT_BRANCH}

This is an ISOLATED git worktree already checked out at origin/${DEFAULT_BRANCH}.
Other handlers have their own worktrees. Only operate within ${WORKTREE_ROOT}.

First, READ ${WORKTREE_ROOT}/CLAUDE.md for full project context (stack, conventions, key files, persona).
If CLAUDE.md is missing, note its absence in the PR description and proceed using best judgment about the project stack and conventions.

GitHub Issue #${ISSUE_NUM}: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

Issue body:
${ISSUE_BODY}

Your job:
1. cd ${WORKTREE_ROOT}  (already on origin/${DEFAULT_BRANCH} — no pull needed)
2. Create a branch: fix/issue-${ISSUE_NUM}-<slug>  (or feat/issue-${ISSUE_NUM}-<slug> for features)
   If a branch named fix/issue-${ISSUE_NUM}-* or feat/issue-${ISSUE_NUM}-* already exists on origin, delete it first:
   git push origin --delete <existing-branch-name>
3. Implement the change. Follow CLAUDE.md conventions.
$( [ -n "$DEV_VALIDATION_CMD" ] && echo "4. Run validation: ${DEV_VALIDATION_CMD//\{project_root\}/$ROOT}" )
5. Before committing, verify there are actual staged changes:
   git diff --cached --quiet && echo 'WARNING: no staged changes' || true
   If there are no changes to commit, comment on the issue explaining why (e.g. already implemented, out of scope) and add label 'needs-clarification' instead of opening an empty PR.
6. Commit: git commit -m '[${COMMIT_PREFIX}-${ISSUE_NUM}] <short description>'
7. Push the branch and open a PR:
   gh pr create --repo ${REPO} --draft --title 'Draft: [${COMMIT_PREFIX}-${ISSUE_NUM}] <short description>' \\
     --body 'Closes #${ISSUE_NUM}

## Changes
<what you changed and why>

## Test Plan
<what QA should verify>' \\
     --label ${REVIEW_LABEL}
8. On your own issue — this step is MANDATORY to signal success to the pipeline:
   gh issue edit ${ISSUE_NUM} --repo ${REPO} --remove-label in-progress --remove-label dev --remove-label plan --remove-label needs-review --remove-label review-pending --add-label ${REVIEW_LABEL}

IMPORTANT: The issue MUST end this run with label '${REVIEW_LABEL}' (or 'needs-clarification' if blocked). Verify with:
   gh issue view ${ISSUE_NUM} --repo ${REPO} --json labels

If blocked by missing context or an architectural decision, comment on the issue and add label 'needs-clarification' instead of opening a PR.
$(loop_cli_hint)
EOF
)

cleanup_worktree() {
    git -C "$ROOT" worktree remove "$WORKTREE_ROOT" --force 2>/dev/null \
        || rm -rf "$WORKTREE_ROOT"
    git -C "$ROOT" worktree prune 2>/dev/null || true
}

LOG_CAPTURE_START=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
if loop_run_agent "$TASK_PROMPT" "$WORKTREE_ROOT" 2>&1 | tee -a "$LOG_FILE"; then
    log "dev agent succeeded for #$ISSUE_NUM"
    bounty_report "dev_done" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" issue_num="$ISSUE_NUM" || true
    loop_notify "✅ [$SLUG] #$ISSUE_NUM dev done"
    retry_clear
    # Belt-and-braces: if the agent forgot to swap labels, clean up here.
    backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    # Locate the PR opened for this issue (by head ref pattern or Closes reference).
    # Uses backend_list_open_prs_raw so this works on both GitHub and GitLab.
    _dev_pr_num=$(backend_list_open_prs_raw "$REPO" | python3 -c "
import json, re, sys
num = '${ISSUE_NUM}'
prs = json.load(sys.stdin)
matches = [
    pr['number'] for pr in prs
    if re.match(r'^(fix|feat)/issue-' + re.escape(num) + r'-', pr.get('headRefName', ''))
    or re.search(r'Closes #' + re.escape(num) + r'([^0-9]|\$)', pr.get('body', ''), re.IGNORECASE)
]
if matches:
    print(sorted(matches)[-1])
" 2>/dev/null || true)
    if [ -z "$_dev_pr_num" ]; then
        log "WARN: no open PR found for issue #$ISSUE_NUM after dev agent — adding 'needs-clarification'"
        backend_remove_label "$REPO" "$ISSUE_NUM" dev plan in-progress
        backend_add_label "$REPO" "$ISSUE_NUM" needs-clarification
    else
        log "belt-and-braces: found PR #$_dev_pr_num for issue #$ISSUE_NUM"
        if ! backend_pr_has_any_label "$REPO" "$_dev_pr_num" \
                review-pending needs-review changes-requested needs-rework in-review needs-clarification blocked 'done'; then
            log "WARN: PR #$_dev_pr_num has no progression label after dev agent — adding '${REVIEW_LABEL}'"
            backend_add_label "$REPO" "$_dev_pr_num" "$REVIEW_LABEL"
        fi
        # Strip both legacy and canonical issue-side names so the issue ends single-state
        backend_remove_label "$REPO" "$ISSUE_NUM" needs-review review-pending plan dev in-progress
    fi
    cleanup_worktree
else
    n=$(retry_incr)
    log "dev agent failed for #$ISSUE_NUM (attempt $n/$MAX_RETRIES)"
    bounty_report "dev_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" issue_num="$ISSUE_NUM" detail="attempt ${n}/${MAX_RETRIES}" || true
    if [ "$n" -ge "$MAX_RETRIES" ]; then
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
        backend_add_label "$REPO" "$ISSUE_NUM" blocked
        _fail_body_file=$(mktemp /tmp/loop-fail-XXXXXX.md)
        {
            echo "Automated dev cycle failed ${MAX_RETRIES} times. Needs human review."
            echo ""
            echo "<details><summary>Last agent output</summary>"
            echo ""
            echo '```'
            tail -n +"$((LOG_CAPTURE_START + 1))" "$LOG_FILE" \
                | sed 's/\(ANTHROPIC_API_KEY=\|GITHUB_TOKEN=\|GH_TOKEN=\|_SECRET=\)[^ ]*/\1REDACTED/g' \
                | tail -40
            echo '```'
            echo "</details>"
        } > "$_fail_body_file"
        gh issue comment "$ISSUE_NUM" --repo "$REPO" --body-file "$_fail_body_file" 2>/dev/null || true
        rm -f "$_fail_body_file"
        loop_notify "❌ [$SLUG] #$ISSUE_NUM dev failed: agent failed after $MAX_RETRIES attempts"
    else
        backend_remove_label "$REPO" "$ISSUE_NUM" in-progress
    fi
    cleanup_worktree
    exit 1
fi
