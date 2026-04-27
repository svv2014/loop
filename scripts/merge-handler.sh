#!/usr/bin/env bash
# merge-handler.sh — handles one loop.pr_merge event.
# Deprecated name: prefer scripts/merger.sh
# Merges the PR using the project's configured strategy and closes the
# linked issue with label 'done'. No agent call — this is mechanical.

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

LOG_FILE="${LOOP_LOG_DIR}/loop-merge-handler.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [merge-handler] $*" | tee -a "$LOG_FILE"; }

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

STRATEGY_FLAG="--squash"
case "${MERGE_STRATEGY:-squash}" in
    squash) STRATEGY_FLAG="--squash" ;;
    merge)  STRATEGY_FLAG="--merge" ;;
    rebase) STRATEGY_FLAG="--rebase" ;;
    *)      log "WARN: unknown merge strategy '${MERGE_STRATEGY}', defaulting to squash" ;;
esac

log "merging PR #${PR_NUM} in ${REPO} (${MERGE_STRATEGY})"
bounty_report "merge_start" model="${LOOP_AGENT_MODEL:-sonnet}" role=merge project="$SLUG" pr_num="$PR_NUM" || true
loop_notify "▶️ [$SLUG] PR#$PR_NUM merge starting"

# Pre-flight: if GitHub already knows the PR is CONFLICTING, don't even try
# to merge — bounce straight to dev-rework so the dev agent rebases.
MERGE_STATE=$(backend_pr_view "$REPO" "$PR_NUM" --json mergeable,mergeStateStatus 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergeable',''), d.get('mergeStateStatus',''))")
case "$MERGE_STATE" in
    *CONFLICTING*|*DIRTY*)
        log "PR #${PR_NUM} is CONFLICTING — bouncing to dev-rework (no retry loop)"
        bounty_report "merge_conflict" model="${LOOP_AGENT_MODEL:-sonnet}" role=merge project="$SLUG" pr_num="$PR_NUM" || true
        backend_remove_label "$REPO" "$PR_NUM" qa-pass ready-for-qa
        backend_add_label "$REPO" "$PR_NUM" changes-requested
        backend_comment_pr "$REPO" "$PR_NUM" \
            "Merge blocked by conflicts with \`${DEFAULT_BRANCH}\`. Routing back to dev-rework to rebase and resolve."
        exit 0
        ;;
esac

if ! backend_merge_pr "$REPO" "$PR_NUM" "$STRATEGY_FLAG" 2>&1 | tee -a "$LOG_FILE"; then
    # Check if the failure was a conflict discovered at merge time.
    POST_STATE=$(backend_pr_view "$REPO" "$PR_NUM" --json mergeable,mergeStateStatus 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergeable',''), d.get('mergeStateStatus',''))")
    case "$POST_STATE" in
        *CONFLICTING*|*DIRTY*)
            log "merge failed due to conflict — routing to dev-rework"
            bounty_report "merge_conflict" model="${LOOP_AGENT_MODEL:-sonnet}" role=merge project="$SLUG" pr_num="$PR_NUM" || true
            backend_remove_label "$REPO" "$PR_NUM" qa-pass ready-for-qa
            backend_add_label "$REPO" "$PR_NUM" changes-requested
            backend_comment_pr "$REPO" "$PR_NUM" \
                "Merge blocked by conflicts with \`${DEFAULT_BRANCH}\`. Routing back to dev-rework to rebase and resolve."
            exit 0
            ;;
    esac

    # Non-conflict failure (e.g. required check missing, API flake). Don't
    # loop on this either — mark blocked so a human can look.
    log "ERROR: merge failed for non-conflict reason (state=$POST_STATE)"
    bounty_report "merge_failed" model="${LOOP_AGENT_MODEL:-sonnet}" role=merge project="$SLUG" pr_num="$PR_NUM" detail="state=${POST_STATE}" || true
    loop_notify "❌ [$SLUG] PR#$PR_NUM merge failed: merge command failed"
    backend_remove_label "$REPO" "$PR_NUM" qa-pass
    backend_add_label "$REPO" "$PR_NUM" blocked
    backend_comment_pr "$REPO" "$PR_NUM" \
        "Merge failed (state: \`${POST_STATE}\`). Marked \`blocked\` — needs human eyes."
    exit 1
fi

# Find all linked issues via "Closes #N" in PR body (handles multiple closes).
LINKED_ISSUES=$(backend_pr_view "$REPO" "$PR_NUM" --json body --jq .body 2>/dev/null \
    | python3 -c "import re,sys; print(' '.join(re.findall(r'[Cc]loses?\s+#(\d+)', sys.stdin.read() or '')))")

if [ -n "$LINKED_ISSUES" ]; then
    for LINKED_ISSUE in $LINKED_ISSUES; do
        log "closing linked issue #${LINKED_ISSUE} with label 'done'"
        backend_remove_label "$REPO" "$LINKED_ISSUE" qa-pass
        backend_add_label "$REPO" "$LINKED_ISSUE" 'done'
        backend_close_issue "$REPO" "$LINKED_ISSUE"
    done
else
    log "PR #${PR_NUM} had no 'Closes #N' in body — nothing to close"
fi

bounty_report "merge_done" model="${LOOP_AGENT_MODEL:-sonnet}" role=merge project="$SLUG" pr_num="$PR_NUM" || true
loop_notify "✅ [$SLUG] PR#$PR_NUM merge done"

# Append bounty record for this merge.
BOUNTIES_DIR="${LOOP_ROOT}/data"
BOUNTIES_FILE="${BOUNTIES_DIR}/bounties.jsonl"
mkdir -p "$BOUNTIES_DIR"

FIRST_LINKED_ISSUE="${LINKED_ISSUES%% *}"
PR_TITLE=$(backend_pr_view "$REPO" "$PR_NUM" --json title --jq .title 2>/dev/null || echo "")

BOUNTY_RECORD=$(REPO="$REPO" PR_NUM="$PR_NUM" SLUG="$SLUG" \
    LOOP_AGENT="${LOOP_AGENT:-unknown}" \
    LOOP_AGENT_MODEL="${LOOP_AGENT_MODEL:-unknown}" \
    LINKED_ISSUE="$FIRST_LINKED_ISSUE" \
    PR_TITLE="$PR_TITLE" \
    python3 <<'PY'
import json, os, subprocess, datetime

repo   = os.environ['REPO']
pr_num = os.environ['PR_NUM']
slug   = os.environ['SLUG']
agent  = os.environ.get('LOOP_AGENT', 'unknown')
model  = os.environ.get('LOOP_AGENT_MODEL', 'unknown')
linked = os.environ.get('LINKED_ISSUE', '') or None
title  = os.environ.get('PR_TITLE', '')

linked_int = int(linked) if linked and linked.isdigit() else None

raw = subprocess.run(
    ['gh', 'api', f'/repos/{repo}/issues/{pr_num}/events',
     '--jq', '[.[] | select(.event == "labeled") | .label.name]'],
    capture_output=True, text=True
).stdout.strip()
labels_added = json.loads(raw) if raw else []

qa_fail    = bool({'qa-fail', 'qa-failed'} & set(labels_added))
cr_labeled = bool({'changes-requested', 'needs-rework'} & set(labels_added))
rework_count = (labels_added.count('changes-requested') + labels_added.count('needs-rework') +
                labels_added.count('qa-fail') + labels_added.count('qa-failed'))

if qa_fail:
    outcome = 'qa-fail'
    pts = {'planner': 3, 'builder': 1, 'reviewer': 1, 'tester': 3}
elif cr_labeled:
    outcome = 'rework'
    pts = {'planner': 3, 'builder': 2, 'reviewer': 4, 'tester': 2}
else:
    outcome = 'clean'
    pts = {'planner': 3, 'builder': 5, 'reviewer': 3, 'tester': 2}

roles = {role: {'agent': agent, 'model': model, 'points': p} for role, p in pts.items()}
record = {
    'ts':           datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'slug':         slug,
    'issue':        linked_int,
    'pr':           int(pr_num),
    'outcome':      outcome,
    'roles':        roles,
    'rework_count': rework_count,
    'title':        title,
}
print(json.dumps(record))
PY
) || true

if [ -n "$BOUNTY_RECORD" ]; then
    echo "$BOUNTY_RECORD" >> "$BOUNTIES_FILE"
    BOUNTY_SUMMARY=$(echo "$BOUNTY_RECORD" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(f'outcome={d[\"outcome\"]} rework_count={d[\"rework_count\"]} total_points={sum(r[\"points\"] for r in d[\"roles\"].values())}')" 2>/dev/null || echo "")
    log "bounty recorded: ${BOUNTY_SUMMARY}"
else
    log "WARN: bounty record could not be generated for PR #${PR_NUM}"
fi

# Auto-invoke judge to classify the merged PR and post a verdict.
"$LOOP_ROOT/scripts/judge.sh" "$PR_NUM" "$REPO" "" "dev" "$SLUG" 2>&1 | tee -a "$LOG_FILE" || true

log "merge-handler done for PR #${PR_NUM}"
