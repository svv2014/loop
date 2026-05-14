#!/usr/bin/env bash
# scripts/judge.sh — AI judge: reads PR timeline, classifies outcome, posts verdict.
# Usage: judge.sh <pr_number> <repo> [model] [role] [project]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LOOP_ROOT/lib/env.sh"
source "$LOOP_ROOT/lib/bounty.sh"

PR_NUM="${1:-}"
REPO="${2:-}"
JUDGE_MODEL="${LOOP_JUDGE_MODEL:-sonnet}"
MODEL="${3:-$JUDGE_MODEL}"
ROLE="${4:-judge}"
PROJECT="${5:-}"

if [ -z "$PR_NUM" ] || [ -z "$REPO" ]; then
    echo "Usage: $0 <pr_number> <repo> [model] [role] [project]" >&2
    exit 1
fi

JUDGE_STARTED_AT=$(date +%s)
bounty_report "judge_start" \
    model="$MODEL" role="$ROLE" project="$PROJECT" \
    pr_num="$PR_NUM" || true

# ── Fetch PR timeline via gh ──────────────────────────────────────────────────

PR_JSON=$(gh pr view "$PR_NUM" --repo "$REPO" \
    --json number,title,state,labels,reviews,commits,comments,headRefName,baseRefName \
    2>/dev/null) || { echo "ERROR: could not fetch PR #$PR_NUM" >&2; exit 1; }

TIMELINE_JSON=$(gh api "repos/${REPO}/issues/${PR_NUM}/timeline" \
    --paginate --jq '[.[] | {event: .event, actor: .actor.login, created_at: .created_at, label: .label.name}]' \
    2>/dev/null) || TIMELINE_JSON="[]"

# ── Build judge prompt ────────────────────────────────────────────────────────

JUDGE_PROMPT=$(cat <<EOF
You are the Loop Pipeline Judge. Analyze this PR and classify its outcome.

PR data:
${PR_JSON}

Timeline events:
${TIMELINE_JSON}

Classify the outcome as exactly one of:
- clean         : PR was reviewed, passed QA, merged without rework requests
- rework        : PR received a "changes requested" review and needed rework
- qa-fail-rework: PR was labeled qa-fail and sent back for rework
- blocked       : PR is blocked / stuck with no progression

Then compute per-role points:
- dev role:      clean=+3, rework=-1, qa-fail-rework=-2, blocked=0
- reviewer role: clean=+1, rework=0, qa-fail-rework=-1, blocked=0
- qa role:       clean=+3, rework=0, qa-fail-rework=+3 if the QA comment shows unmet acceptance criteria (NOT_FOUND or PARTIAL) else +1, blocked=0

Note: for the qa role, check PR comments for a "### QA verification" block. If that block contains
NOT_FOUND or PARTIAL criteria, the qa-fail-rework outcome is a valid catch worth +3.
If the QA comment is absent or shows only validation failures (no AC analysis), award +1.

Output ONLY valid JSON with these exact keys (no markdown, no explanation):
{
  "outcome": "<one of the four outcomes>",
  "points": <integer points for the primary role>,
  "summary": "<one sentence explaining why>"
}
EOF
)

# ── Invoke claude to classify ─────────────────────────────────────────────────

VERDICT_JSON=$(claude -p --model "$MODEL" --output-format text \
    "$JUDGE_PROMPT" 2>/dev/null) || VERDICT_JSON=""

# Strip markdown fences if present
VERDICT_JSON=$(printf '%s' "$VERDICT_JSON" | sed 's/^```[a-z]*//;s/^```//' | tr -d '\n' | sed 's/^[^{]*//')

# Validate we got something usable
if ! printf '%s' "$VERDICT_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    VERDICT_JSON='{"outcome":"blocked","points":0,"summary":"Judge could not parse PR outcome."}'
fi

OUTCOME=$(printf '%s' "$VERDICT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('outcome','blocked'))")
POINTS=$(printf '%s'  "$VERDICT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('points',0))")
SUMMARY=$(printf '%s' "$VERDICT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('summary',''))")

# ── POST verdict to Bounty Monitor ────────────────────────────────────────────

VERDICT_PAYLOAD=$(
    _BO="$OUTCOME" _BPT="$POINTS" _BS="$SUMMARY" \
    _BM="$MODEL" _BR="$ROLE" _BP="$PROJECT" \
    _BPN="$PR_NUM" _BREPO="$REPO" \
    python3 - <<'PY'
import json, os
d = {
    "pr_num":  int(os.environ.get("_BPN", "0") or 0),
    "repo":    os.environ.get("_BREPO", ""),
    "outcome": os.environ.get("_BO", "blocked"),
    "points":  int(os.environ.get("_BPT", "0") or 0),
    "summary": os.environ.get("_BS") or None,
    "model":   os.environ.get("_BM") or None,
    "role":    os.environ.get("_BR") or None,
    "project": os.environ.get("_BP") or None,
}
print(json.dumps(d))
PY
) 2>/dev/null || true

if [ -n "$VERDICT_PAYLOAD" ]; then
    curl -sf \
        --max-time "$BOUNTY_TIMEOUT" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$VERDICT_PAYLOAD" \
        "${BOUNTY_URL}/api/verdict" \
        >/dev/null 2>&1 || true
fi

# Also report as a feed event
JUDGE_FINISHED_AT=$(date +%s)
JUDGE_DURATION_SECONDS=$((JUDGE_FINISHED_AT - JUDGE_STARTED_AT))
if [ "$JUDGE_DURATION_SECONDS" -lt 0 ]; then
    JUDGE_DURATION_SECONDS=0
fi

bounty_report "judge_done" \
    model="$MODEL" role="$ROLE" project="$PROJECT" \
    pr_num="$PR_NUM" \
    duration_seconds="$JUDGE_DURATION_SECONDS" \
    detail="outcome=${OUTCOME} points=${POINTS} ${SUMMARY}" || true

# ── Comment on PR ─────────────────────────────────────────────────────────────

OUTCOME_EMOJI="&#9878;&#65039;"
case "$OUTCOME" in
    clean)          OUTCOME_EMOJI="✅" ;;
    rework)         OUTCOME_EMOJI="🔧" ;;
    qa-fail-rework) OUTCOME_EMOJI="🔴" ;;
    blocked)        OUTCOME_EMOJI="🚫" ;;
esac

PR_COMMENT=$(cat <<COMMENT
### ${OUTCOME_EMOJI} Judge Verdict: \`${OUTCOME}\`

**Points:** ${POINTS:+"+"}${POINTS}
**Summary:** ${SUMMARY}

*Powered by Loop Bounty Monitor*
COMMENT
)

gh pr comment "$PR_NUM" --repo "$REPO" --body "$PR_COMMENT" 2>/dev/null || true

echo "Judge verdict: outcome=${OUTCOME} points=${POINTS}"
