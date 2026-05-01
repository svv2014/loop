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
# shellcheck source=../lib/labels.sh
source "$LOOP_ROOT/lib/labels.sh"
source "$LOOP_ROOT/lib/bounty.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/recovery.sh
source "$LOOP_ROOT/lib/recovery.sh"

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
        backend_remove_label "$REPO" "$PR_NUM" qa-pass "$LOOP_LABEL_DEPRECATED_READY_FOR_QA"
        backend_add_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED"
        backend_comment_pr "$REPO" "$PR_NUM" \
            "Merge blocked by conflicts with \`${DEFAULT_BRANCH}\`. Routing back to dev-rework to rebase and resolve."
        exit 0
        ;;
esac

# Dev-handler opens all PRs as drafts; promote to ready before merging.
backend_pr_ready "$REPO" "$PR_NUM" 2>&1 | tee -a "$LOG_FILE" || true

if ! backend_merge_pr "$REPO" "$PR_NUM" "$STRATEGY_FLAG" 2>&1 | tee -a "$LOG_FILE"; then
    # Check if the failure was a conflict discovered at merge time.
    POST_STATE=$(backend_pr_view "$REPO" "$PR_NUM" --json mergeable,mergeStateStatus 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergeable',''), d.get('mergeStateStatus',''))")
    case "$POST_STATE" in
        *CONFLICTING*|*DIRTY*)
            log "merge failed due to conflict — routing to dev-rework"
            bounty_report "merge_conflict" model="${LOOP_AGENT_MODEL:-sonnet}" role=merge project="$SLUG" pr_num="$PR_NUM" || true
            backend_remove_label "$REPO" "$PR_NUM" qa-pass "$LOOP_LABEL_DEPRECATED_READY_FOR_QA"
            backend_add_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED"
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

# ── Release-PR: tag + publish GitHub release ─────────────────────────────────
# If this was a release PR, tag the merged commit and publish a GitHub release.
# Non-fatal: all git/gh calls are guarded with || true.
if backend_pr_has_any_label "$REPO" "$PR_NUM" "release-pr"; then
    git -C "$ROOT" pull origin "$DEFAULT_BRANCH" --ff-only 2>/dev/null || true
    _release_version=$(cat "$ROOT/VERSION" 2>/dev/null || echo "")
    if [ -n "$_release_version" ]; then
        log "[$REPO] release-pr merged: tagging v${_release_version}"
        git -C "$ROOT" tag "v${_release_version}" 2>/dev/null || true
        git -C "$ROOT" push origin "v${_release_version}" 2>/dev/null || true
        gh release create "v${_release_version}" \
            --repo "$REPO" \
            --notes-from-tag \
            --title "v${_release_version}" \
            2>/dev/null || true
        log "[$REPO] GitHub release v${_release_version} created"
    else
        log "WARN: release-pr merged but VERSION file not found or empty — skipping tag"
    fi
fi

# Find all linked issues via GitHub's auto-close keywords in PR body (#200).
# Recognises closes/close/closed, fixes/fix/fixed, resolves/resolve/resolved
# — same set GitHub uses natively for auto-close. Previous regex matched
# only [Cc]loses?, so PRs using Fixes/Resolves left their issues open.
LINKED_ISSUES=$(backend_pr_view "$REPO" "$PR_NUM" --json body --jq .body 2>/dev/null \
    | python3 -c "import re,sys; print(' '.join(re.findall(r'(?:[Cc]los(?:e|es|ed)|[Ff]ix(?:|es|ed)|[Rr]esolv(?:e|es|ed))\s+#(\d+)', sys.stdin.read() or '')))")

# Strip all pipeline-stage labels from the merged PR (issue #166).
# Orthogonal labels (priority, semver:*, release-pr, safe-to-test, bug,
# feature, epic, tracker, blocked) are preserved.
log "stripping pipeline-stage labels from merged PR #${PR_NUM}"
loop_strip_pipeline_labels "$REPO" "$PR_NUM" >/dev/null || true

if [ -n "$LINKED_ISSUES" ]; then
    for LINKED_ISSUE in $LINKED_ISSUES; do
        log "closing linked issue #${LINKED_ISSUE} with label 'done' (stripping stale stage labels)"
        loop_strip_pipeline_labels "$REPO" "$LINKED_ISSUE" >/dev/null || true
        backend_add_label "$REPO" "$LINKED_ISSUE" 'done'
        backend_close_issue "$REPO" "$LINKED_ISSUE"
    done
else
    log "PR #${PR_NUM} had no 'Closes #N' in body — nothing to close"
fi

# ── Dependency fanout — wake any blocked tickets whose dep just resolved ────
# When a PR merges (and its linked issues close), open issues/PRs that listed
# the merged PR or any closed issue as a blocker may now be unblocked. Run
# the existing recovery sweep against this slug to re-evaluate every blocked
# ticket immediately, instead of waiting for the next 15-min reconciler tick.
log "dep-fanout: re-evaluating blocked tickets in $REPO after merge of PR #${PR_NUM}"
DRY_RUN=false recovery_check_dependencies "$SLUG" \
    || log "dep-fanout: recovery_check_dependencies returned non-zero (continuing)"

# ── Changelog update ─────────────────────────────────────────────────────────
# Non-fatal: run in a subshell so any error never aborts a successful merge.
(
  CHANGELOG="${ROOT}/CHANGELOG.md"

  PR_META=$(backend_pr_view "$REPO" "$PR_NUM" --json title,labels 2>/dev/null || echo "{}")
  CL_TITLE=$(echo "$PR_META" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('title',''))")
  # shellcheck disable=SC2086
  CL_LABELS=$(echo "$PR_META" | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(l['name'] for l in d.get('labels',[])))")

  case "$CL_TITLE" in
    "chore(changelog):"*|"chore(release):"*)
      log "changelog: skipping — PR title starts with chore(changelog/release):"
      exit 0
      ;;
  esac

  CL_SECTION="Changed"
  # shellcheck disable=SC2086
  for _lbl in $CL_LABELS; do
    case "$_lbl" in
      bug)     CL_SECTION="Fixed";  break ;;
      feature) CL_SECTION="Added";  break ;;
    esac
  done

  if [ ! -f "$CHANGELOG" ]; then
    log "WARN: $CHANGELOG not found — skipping changelog entry"
    exit 0
  fi

  git -C "$ROOT" pull --ff-only origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE" || {
    log "WARN: git pull before changelog edit failed — skipping"
    exit 0
  }

  _py_rc=0
  CHANGELOG_PATH="$CHANGELOG" PR_NUM="$PR_NUM" CL_TITLE="$CL_TITLE" CL_SECTION="$CL_SECTION" \
  python3 <<'PY' >> "$LOG_FILE" 2>&1 || _py_rc=$?
import sys, os, re

changelog_path = os.environ['CHANGELOG_PATH']
pr_num         = os.environ['PR_NUM']
pr_title       = os.environ['CL_TITLE']
section        = os.environ['CL_SECTION']
entry          = f"- {pr_title} (#{pr_num})"

with open(changelog_path, 'r') as f:
    content = f.read()

if '## [Unreleased]' not in content:
    print("WARN: no [Unreleased] section found — skipping changelog entry")
    sys.exit(1)

if entry in content:
    print("INFO: changelog entry already present — skipping")
    sys.exit(0)

section_header   = f"### {section}"
unreleased_match = re.search(r'## \[Unreleased\][^\n]*\n', content)
unreleased_end   = unreleased_match.end()

next_section_match = re.search(r'\n## ', content[unreleased_end:])
block_end = (unreleased_end + next_section_match.start()) if next_section_match else len(content)

unreleased_block = content[unreleased_end:block_end]
sub_match = re.search(r'### ' + re.escape(section) + r'[^\n]*\n', unreleased_block)

if sub_match:
    sub_body_start = unreleased_end + sub_match.end()
    next_sub = re.search(r'\n### ', unreleased_block[sub_match.end():])
    if next_sub:
        insert_pos = sub_body_start + next_sub.start()
    else:
        insert_pos = block_end
        while insert_pos > sub_body_start and content[insert_pos - 1] == '\n':
            insert_pos -= 1
    new_content = content[:insert_pos] + f"\n{entry}" + content[insert_pos:]
else:
    insert_pos = block_end
    while insert_pos > unreleased_end and content[insert_pos - 1] == '\n':
        insert_pos -= 1
    new_content = content[:insert_pos] + f"\n\n{section_header}\n{entry}" + content[insert_pos:]

with open(changelog_path, 'w') as f:
    f.write(new_content)
PY

  if [ "$_py_rc" -ne 0 ]; then
    log "WARN: changelog edit skipped (rc=$_py_rc)"
    exit 0
  fi

  git -C "$ROOT" add "$CHANGELOG"
  if git -C "$ROOT" diff --cached --quiet; then
    log "changelog: no changes to commit"
    exit 0
  fi
  git -C "$ROOT" commit -m "chore(changelog): record #${PR_NUM}"
  git -C "$ROOT" push origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE" \
    || log "WARN: changelog push failed — entry committed locally but not pushed"
  log "changelog: appended entry for PR #${PR_NUM} under ### ${CL_SECTION}"
) || log "WARN: changelog update block encountered an error — merge still succeeded"

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
    LOOP_LBL_CR="$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" \
    LOOP_LBL_NR="$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" \
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

_LBL_CR = os.environ['LOOP_LBL_CR']
_LBL_NR = os.environ['LOOP_LBL_NR']
qa_fail    = bool({'qa-fail', 'qa-failed'} & set(labels_added))
cr_labeled = bool({_LBL_CR, _LBL_NR} & set(labels_added))
rework_count = (labels_added.count(_LBL_CR) + labels_added.count(_LBL_NR) +
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
