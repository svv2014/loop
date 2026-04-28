#!/usr/bin/env bash
# qa-handler.sh — handles one loop.pr_qa event.
# Deprecated name: prefer scripts/tester.sh
#
# Event payload: {"slug","repo","pr_number","pr_title","pr_url"}
#
# Flow: run qa.validation_cmd if configured — on zero exit, label 'qa-pass';
# on non-zero, label 'qa-failed'. If no validation_cmd is configured for the
# project, auto-pass (trust the review handler's decision).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"

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

# Draft check — skip QA without touching retry counter.
_is_draft=$(gh pr view "$PR_NUM" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")
if [ "$_is_draft" = "true" ]; then
    log "PR #$PR_NUM is a draft — skipping QA"
    gh label create draft --color "#808080" --description "PR is in Draft state" --repo "$REPO" 2>/dev/null || true
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_add_label    "$REPO" "$PR_NUM" draft
    backend_comment_pr   "$REPO" "$PR_NUM" "PR is in Draft state — review skipped. When ready: mark the PR ready for review on GitHub, remove the \`draft\` label, and re-apply \`needs-review\` to re-enter the pipeline."
    exit 0
fi

if [ -z "${QA_VALIDATION_CMD:-}" ]; then
    log "no qa.validation_cmd configured for $SLUG — auto-passing"
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_remove_label "$REPO" "$PR_NUM" qa-failed
    backend_remove_label "$REPO" "$PR_NUM" qa-fail
    backend_remove_label "$REPO" "$PR_NUM" qa-pass
    backend_add_label "$REPO" "$PR_NUM" qa-pass
    exit 0
fi

loop_notify "▶️ [$SLUG] PR#$PR_NUM qa starting"

QA_TIMEOUT="${QA_TIMEOUT_SECONDS:-600}"
log "running qa validation: $QA_VALIDATION_CMD (cwd=$ROOT, timeout=${QA_TIMEOUT}s)"
if (cd "$ROOT" && timeout "$QA_TIMEOUT" bash -c "$QA_VALIDATION_CMD") 2>&1 | tee -a "$LOG_FILE"; then
    log "qa passed for PR #$PR_NUM"
    bounty_report "qa_pass" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "✅ [$SLUG] PR#$PR_NUM qa done"
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_remove_label "$REPO" "$PR_NUM" qa-failed
    backend_remove_label "$REPO" "$PR_NUM" qa-fail
    backend_add_label "$REPO" "$PR_NUM" qa-pass
else
    log "qa failed for PR #$PR_NUM"
    bounty_report "qa_fail" model="${LOOP_AGENT_MODEL:-sonnet}" role=qa project="$SLUG" pr_num="$PR_NUM" || true
    loop_notify "❌ [$SLUG] PR#$PR_NUM qa failed: validation command failed"
    backend_remove_label "$REPO" "$PR_NUM" needs-qa
    backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
    backend_remove_label "$REPO" "$PR_NUM" approved
    backend_remove_label "$REPO" "$PR_NUM" qa-pass
    backend_remove_label "$REPO" "$PR_NUM" qa-fail
    backend_add_label "$REPO" "$PR_NUM" qa-failed
    backend_comment_pr "$REPO" "$PR_NUM" \
        "QA validation failed. See loop-qa-handler.log for details."
    exit 1
fi
