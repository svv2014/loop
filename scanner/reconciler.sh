#!/usr/bin/env bash
# reconciler.sh — Loop pipeline housekeeping.
#
# Detects and (where safe) fixes drift that the event-driven pipeline doesn't
# self-correct. Runs every ~15 min via launchd (com.example.loop-reconciler).
#
# Checks (per project):
#   1. DUPLICATE_PRS — multiple OPEN PRs close the same issue (body contains
#      "Closes #N"). Keep the newest PR number, close the rest with a comment.
#   2. ORPHANED_CLAIMS — issue carries a "claimed" label (the deprecated
#      review-trigger alias) but no OPEN PR closes it. Strip the stale label
#      so the scanner/dev handler picks the issue up again.
#   3. STALE_PRS — PRs sitting >24h waiting on review/rework without an
#      update. Logged + announced to Signal ops (no auto-fix).
#
# Modes:
#   reconciler.sh                 # single sweep across all projects
#   reconciler.sh --dry-run       # report findings only, no mutations
#   reconciler.sh --slug ppl      # limit to one project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"
# shellcheck source=../lib/labels.sh
source "$LOOP_ROOT/lib/labels.sh"
# shellcheck source=../lib/recovery.sh
source "$LOOP_ROOT/lib/recovery.sh"
# shellcheck source=../lib/author_gate.sh
source "$LOOP_ROOT/lib/author_gate.sh"
# shellcheck source=../lib/stage.sh
source "$LOOP_ROOT/lib/stage.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-reconciler.log"
LOCK_FILE="/tmp/loop-reconciler.lock"
# Notifications via loop_notify (configured in loop.env)
STALE_PR_HOURS="${LOOP_STALE_PR_HOURS:-24}"

DRY_RUN=false
ONLY_SLUG=""

# Test hook: when LOOP_RECONCILER_LIB_ONLY=1 is set, skip the arg-parser
# (which would reject the bats-injected $0/$@) and skip the main run at
# the bottom — we only want function definitions for unit tests.
if [ "${LOOP_RECONCILER_LIB_ONLY:-0}" != "1" ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --slug)    ONLY_SLUG="$2"; shift 2 ;;
            -h|--help)
                sed -n '1,20p' "$0"; exit 0 ;;
            *) echo "unknown arg: $1" >&2; exit 2 ;;
        esac
    done
fi

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local line; line="[$(date '+%Y-%m-%d %H:%M:%S')] [reconciler] $*"
    if [ -t 2 ]; then
        printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

# Single-instance lock (atomic set-once, steals stale PID).
acquire_lock() {
    while true; do
        if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
            trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
            return 0
        fi
        local holder; holder=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -f "$LOCK_FILE"; continue
        fi
        log "Already running (PID $holder). Exiting."
        exit 0
    done
}


# Parse "Closes #N", "closes #N", "Fixes #N", "Resolves #N" from PR body.
# Emits each referenced issue number on its own line.
pr_closes_issues() {
    local body="$1"
    printf '%s\n' "$body" | grep -oEi '(clos(e|es|ed)|fix(|es|ed)|resolv(e|es|ed)) +#[0-9]+' \
        | grep -oE '#[0-9]+' | tr -d '#' | sort -u
}

# --- Check 1: duplicate PRs per issue --------------------------------------
reconcile_duplicate_prs() {
    local repo="$1"
    log "[$repo] scanning open PRs for duplicates"

    # Fetch all open PRs with number, body, createdAt
    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo")

    # Build map: issue_num -> [pr_num,pr_num,...]
    # Selection rule (operator-preference): when multiple PRs close the same
    # issue, prefer operator-authored over bot-authored. Within the same
    # trust tier, the older PR wins so in-flight work is preserved instead
    # of destroyed. External-contributor PRs (author NOT in ALLOWED_AUTHORS,
    # not a bot) are EXCLUDED from dedup-close — the reconciler must not
    # auto-close external contributions; the operator decides.
    local map; map=$(PRS="$prs_json" ALLOWED="${ALLOWED_AUTHORS:-}" python3 - <<'PY'
import json, re, os

prs = json.loads(os.environ['PRS'])
allowed = {a.strip() for a in os.environ.get('ALLOWED', '').replace(',', ' ').split() if a.strip()}

def tier(pr):
    """Lower tier = higher priority to KEEP. 0=operator, 1=bot, 2=external."""
    author = pr.get('author', '') or ''
    if not allowed or author in allowed:
        # Empty allow-list disables gating — treat all authors as tier 0.
        return 0
    if author.endswith('[bot]'):
        return 1
    return 2

m = {}
pat = re.compile(r'(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\s+#(\d+)', re.I)
for pr in prs:
    seen = set()
    for n in pat.findall(pr.get('body') or ''):
        if n in seen:
            continue
        seen.add(n)
        m.setdefault(n, []).append({
            'pr': pr['number'],
            'createdAt': pr.get('createdAt', ''),
            'title': pr.get('title', ''),
            'author': pr.get('author', '') or '',
            'tier': tier(pr),
        })

for issue, plist in m.items():
    if len(plist) <= 1:
        continue

    # Skip dedup entirely if any participant is an external contributor.
    # Operator must triage; the reconciler must not auto-close external PRs.
    if any(p['tier'] == 2 for p in plist):
        continue

    # Sort: lower tier first (operator > bot), then older PR first so
    # in-flight operator work is preserved over newer bot-authored dupes.
    plist.sort(key=lambda x: (x['tier'], x['pr']))
    keep = plist[0]
    for dup in plist[1:]:
        print(f"{issue}\t{keep['pr']}\t{dup['pr']}\t{dup['title'][:60]}\t{keep['author']}\t{dup['author']}")
PY
)

    if [ -z "$map" ]; then
        log "[$repo] no duplicate PRs"
        return 0
    fi

    while IFS=$'\t' read -r issue keep dup title keep_author dup_author; do
        [ -z "$issue" ] && continue
        log "[$repo] DUP issue #$issue: keep PR#$keep (author=$keep_author), close PR#$dup (author=$dup_author) — $title"
        loop_notify "Loop reconciler: $repo — closing duplicate PR#$dup (author $dup_author) for issue #$issue; keeping PR#$keep (author $keep_author)"
        $DRY_RUN && continue
        backend_comment_pr "$repo" "$dup" \
            "Closed by Loop reconciler — duplicate of #$keep (both close issue #$issue)."
        backend_close_pr "$repo" "$dup" --delete-branch \
            || log "[$repo] failed to close PR#$dup"
    done <<< "$map"
}

# --- Check 2: orphaned claimed issues --------------------------------------
# "Claimed" markers on issues = the deprecated review trigger alias
# (dev-handler set it when opening a PR). If the matching PR got closed
# without merging, the issue stays stuck under that alias with no active
# PR. Reset so the pipeline can retry.
reconcile_orphaned_claims() {
    local repo="$1"
    log "[$repo] scanning for orphaned ${LOOP_LABEL_DEPRECATED_REVIEW_PENDING} issues"

    local issues_json issues_new_json
    issues_json=$(backend_list_open_issues_raw "$repo" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING")
    issues_new_json=$(backend_list_open_issues_raw "$repo" "$LOOP_LABEL_NEEDS_REVIEW")
    # Merge both result sets, deduplicating by issue number.
    issues_json=$(ISS_A="$issues_json" ISS_B="$issues_new_json" python3 -c '
import json, os
a = json.loads(os.environ["ISS_A"])
b = json.loads(os.environ["ISS_B"])
seen = {}
for i in a + b:
    seen[i["number"]] = i
print(json.dumps(list(seen.values())))
')

    local open_prs_json
    open_prs_json=$(backend_list_open_prs_raw "$repo")
    local merged_prs_json
    merged_prs_json=$(backend_list_merged_prs_raw "$repo")

    # Classify orphans into two buckets:
    #   "reset"    — no PR closes this issue (reset label to dev, pipeline retries)
    #   "merged"   — a PR already merged closing it (strip the alias, close issue)
    # Grace window: skip issues touched in last 10 min (handler mid-flight).
    local orphans
    orphans=$(ISS="$issues_json" OPEN="$open_prs_json" MERGED="$merged_prs_json" python3 - <<'PY'
import json, re, os, datetime as dt
issues = json.loads(os.environ['ISS'])
open_prs = json.loads(os.environ['OPEN'])
merged_prs = json.loads(os.environ['MERGED'])
pat = re.compile(r'(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\s+#(\d+)', re.I)
def closed_set(prs):
    s = set()
    for pr in prs:
        for n in pat.findall(pr.get('body') or ''):
            s.add(int(n))
    return s
open_closed = closed_set(open_prs)
merged_closed = closed_set(merged_prs)
now = dt.datetime.now(dt.timezone.utc)
for iss in issues:
    if iss['number'] in open_closed:
        continue
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z','+00:00'))
    if (now - up).total_seconds() < 600:
        continue
    kind = "merged" if iss['number'] in merged_closed else "reset"
    print(f"{kind}\t{iss['number']}\t{iss['title'][:60]}")
PY
)

    if [ -z "$orphans" ]; then
        log "[$repo] no orphaned claims"
        return 0
    fi

    while IFS=$'\t' read -r kind num title; do
        [ -z "$num" ] && continue
        if [ "$kind" = "merged" ]; then
            log "[$repo] STALE-LABEL issue #$num (${LOOP_LABEL_DEPRECATED_REVIEW_PENDING}, PR already merged): $title"
            loop_notify "Loop reconciler: $repo — issue #$num PR merged but ${LOOP_LABEL_DEPRECATED_REVIEW_PENDING} label stuck; stripping + closing issue"
            $DRY_RUN && continue
            backend_remove_label "$repo" "$num" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING" \
                || log "[$repo] failed to strip label from issue #$num"
            backend_comment_issue "$repo" "$num" \
                "Closed by Loop reconciler — merged PR closing this issue didn't auto-close it."
            backend_close_issue "$repo" "$num" \
                || log "[$repo] failed to close issue #$num"
        else
            log "[$repo] ORPHAN issue #$num (${LOOP_LABEL_DEPRECATED_REVIEW_PENDING}, no PR): $title"
            loop_notify "Loop reconciler: $repo — issue #$num has ${LOOP_LABEL_DEPRECATED_REVIEW_PENDING} label but no PR; resetting to dev"
            $DRY_RUN && continue
            backend_remove_label "$repo" "$num" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING" \
                || log "[$repo] failed to relabel issue #$num"
            backend_add_label "$repo" "$num" dev \
                || log "[$repo] failed to add dev label to issue #$num"
        fi
    done <<< "$orphans"
}

# --- Check 4: open PR whose issue already has a merged PR ------------------
# When two PRs race to close the same issue, duplicate-check keeps the newer
# one. But if the older one got merged first, duplicate check (open-only)
# can't see it. This pass closes the stale open PR.
reconcile_obsolete_open_prs() {
    local repo="$1"
    log "[$repo] scanning for open PRs whose issue is already closed by a merged PR"

    local open_prs_json merged_prs_json
    open_prs_json=$(backend_list_open_prs_raw "$repo")
    merged_prs_json=$(backend_list_merged_prs_raw "$repo")

    local obsolete
    obsolete=$(OPEN="$open_prs_json" MERGED="$merged_prs_json" python3 - <<'PY'
import json, re, os
open_prs = json.loads(os.environ['OPEN'])
merged_prs = json.loads(os.environ['MERGED'])
pat = re.compile(r'(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\s+#(\d+)', re.I)
merged_by_issue = {}
for pr in merged_prs:
    for n in pat.findall(pr.get('body') or ''):
        merged_by_issue.setdefault(int(n), pr['number'])
for pr in open_prs:
    for n in pat.findall(pr.get('body') or ''):
        iss = int(n)
        if iss in merged_by_issue:
            print(f"{pr['number']}\t{iss}\t{merged_by_issue[iss]}\t{pr['title'][:60]}")
            break
PY
)

    if [ -z "$obsolete" ]; then
        log "[$repo] no obsolete open PRs"
        return 0
    fi

    while IFS=$'\t' read -r open_pr issue merged_pr title; do
        [ -z "$open_pr" ] && continue
        log "[$repo] OBSOLETE PR#$open_pr (issue #$issue already closed by merged PR#$merged_pr): $title"
        loop_notify "Loop reconciler: $repo — closing obsolete PR#$open_pr (issue #$issue already merged via PR#$merged_pr)"
        $DRY_RUN && continue
        backend_comment_pr "$repo" "$open_pr" \
            "Closed by Loop reconciler — issue #$issue already resolved by merged PR#$merged_pr."
        backend_close_pr "$repo" "$open_pr" --delete-branch \
            || log "[$repo] failed to close PR#$open_pr"
    done <<< "$obsolete"
}

# --- Check 3: stale PRs (report only) --------------------------------------
reconcile_stale_prs() {
    local repo="$1"
    log "[$repo] scanning for stale PRs (>${STALE_PR_HOURS}h)"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo")
    local stale
    local _watched_lbls="$LOOP_LABEL_DEPRECATED_REVIEW_PENDING $LOOP_LABEL_NEEDS_REVIEW $LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED $LOOP_LABEL_DEPRECATED_NEEDS_REWORK $LOOP_LABEL_IN_REVIEW $LOOP_LABEL_DEPRECATED_READY_FOR_QA $LOOP_LABEL_NEEDS_QA $LOOP_LABEL_QA_FAIL qa-failed"
    stale=$(PRS="$prs_json" CUTOFF_H="$STALE_PR_HOURS" WATCHED_LBLS="$_watched_lbls" python3 - <<'PY'
import json, os, datetime as dt
data = json.loads(os.environ['PRS'])
now = dt.datetime.now(dt.timezone.utc)
watched = set(os.environ['WATCHED_LBLS'].split())
cutoff_h = float(os.environ['CUTOFF_H'])
for pr in data:
    labels = {l['name'] for l in pr.get('labels',[])}
    if not (labels & watched): continue
    up = dt.datetime.fromisoformat(pr['updatedAt'].replace('Z','+00:00'))
    age_h = (now - up).total_seconds() / 3600
    if age_h >= cutoff_h:
        print(f"{pr['number']}\t{int(age_h)}\t{','.join(sorted(labels&watched))}\t{pr['title'][:60]}")
PY
    )

    if [ -z "$stale" ]; then
        log "[$repo] no stale PRs"
        return 0
    fi

    while IFS=$'\t' read -r num age labels title; do
        [ -z "$num" ] && continue
        log "[$repo] STALE PR#$num ${age}h in {$labels}: $title"

        # Auto-recover: needs-review stuck >24h → relabel to deprecated review trigger so scanner picks it up
        if echo "$labels" | grep -q "$LOOP_LABEL_NEEDS_REVIEW" && ! echo "$labels" | grep -q "$LOOP_LABEL_IN_REVIEW"; then
            log "[$repo] AUTO-RECOVER PR#$num: ${LOOP_LABEL_NEEDS_REVIEW} → ${LOOP_LABEL_DEPRECATED_REVIEW_PENDING}"
            backend_remove_label "$repo" "$num" "$LOOP_LABEL_NEEDS_REVIEW" || true
            backend_add_label    "$repo" "$num" "$LOOP_LABEL_DEPRECATED_REVIEW_PENDING" || true
            loop_notify "Loop reconciler: $repo — PR#$num auto-recovered ${LOOP_LABEL_NEEDS_REVIEW}→${LOOP_LABEL_DEPRECATED_REVIEW_PENDING} after ${age}h"
        # Auto-recover: has both deprecated qa-ready + needs-rework (belt-and-braces bug) → strip needs-rework
        elif echo "$labels" | grep -q "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" && echo "$labels" | grep -q "$LOOP_LABEL_DEPRECATED_READY_FOR_QA"; then
            log "[$repo] AUTO-RECOVER PR#$num: stripping spurious ${LOOP_LABEL_DEPRECATED_NEEDS_REWORK} (${LOOP_LABEL_DEPRECATED_READY_FOR_QA} already set)"
            backend_remove_label "$repo" "$num" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" || true
            loop_notify "Loop reconciler: $repo — PR#$num stripped spurious ${LOOP_LABEL_DEPRECATED_NEEDS_REWORK} after ${age}h (${LOOP_LABEL_DEPRECATED_READY_FOR_QA} was set)"
        else
            loop_notify "Loop reconciler: $repo — PR#$num stale ${age}h in [$labels]: $title"
        fi
    done <<< "$stale"
}

project_locked() {
    local slug="$1"
    local lock_file="/tmp/loop-locks/${slug}.lock"
    [ -f "$lock_file" ] || return 1
    local pid; pid=$(cat "$lock_file" 2>/dev/null || echo "")
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Treat as unlocked if lock has exceeded the handler TTL (stale watchdog)
    local lock_age ttl
    ttl="${LOOP_LOCK_TTL:-7200}"
    lock_age=$(python3 -c "import os,sys,time; print(int(time.time()-os.stat(sys.argv[1]).st_mtime))" "$lock_file" 2>/dev/null || echo 0)
    [ "$lock_age" -le "$ttl" ]
}

# --- Check 5: needs-clarification issues idle >24h (notify owner) ----------
CLARIFICATION_REMINDER_HOURS="${LOOP_CLARIFICATION_HOURS:-24}"
CLARIFICATION_STATE_DIR="/tmp/loop-clarification-notified"
mkdir -p "$CLARIFICATION_STATE_DIR"

reconcile_needs_clarification() {
    local repo="$1"
    log "[$repo] scanning for stale needs-clarification issues (>${CLARIFICATION_REMINDER_HOURS}h)"

    local issues_json
    issues_json=$(backend_list_open_issues_raw "$repo" "needs-clarification")

    local stale
    stale=$(ISS="$issues_json" CUTOFF_H="$CLARIFICATION_REMINDER_HOURS" python3 - <<'PY'
import json, os, datetime as dt
issues = json.loads(os.environ['ISS'])
now = dt.datetime.now(dt.timezone.utc)
cutoff_h = float(os.environ['CUTOFF_H'])
for iss in issues:
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z','+00:00'))
    age_h = (now - up).total_seconds() / 3600
    if age_h >= cutoff_h:
        print(f"{iss['number']}\t{int(age_h)}\t{iss['title'][:60]}")
PY
    )

    if [ -z "$stale" ]; then
        log "[$repo] no stale needs-clarification issues"
        return 0
    fi

    while IFS=$'\t' read -r num age title; do
        [ -z "$num" ] && continue
        # Only notify once per issue per 24h (avoid spam)
        local state_file="$CLARIFICATION_STATE_DIR/${repo//\//-}-${num}"
        if [ -f "$state_file" ]; then
            local last_notify_age=$(( $(date +%s) - $(stat -f%m "$state_file" 2>/dev/null || echo 0) ))
            if [ "$last_notify_age" -lt 86400 ]; then
                continue  # Already notified within 24h
            fi
        fi
        log "[$repo] STALE needs-clarification #$num (${age}h): $title"
        loop_notify "🔔 Issue needs your input (${age}h waiting): $repo#$num — $title"
        touch "$state_file"
    done <<< "$stale"
}

# --- Check 6: try to unblock stuck issues ----------------------------------
# Issues labeled `blocked` or `needs-clarification` whose body or comments
# explicitly declare dependencies via a "Blocked by:" / "Waiting on:" /
# "Depends on:" line listing #N references. If all referenced issues are
# CLOSED, relabel back to `dev` so the pipeline retries.
#
# Conservative by design: only acts on tickets that declare their deps
# explicitly. No heuristic parsing of prose.
reconcile_unblock() {
    local repo="$1"
    log "[$repo] scanning blocked/needs-clarification issues for unblock conditions"

    # Run both queries and merge (OR semantics — gh's multi --label is AND).
    local blocked_json clarif_json issues_json
    blocked_json=$(backend_list_open_issues_raw "$repo" "blocked")
    clarif_json=$(backend_list_open_issues_raw "$repo" "needs-clarification")
    issues_json=$(BL="$blocked_json" CL="$clarif_json" python3 -c '
import json, os
a = json.loads(os.environ["BL"])
b = json.loads(os.environ["CL"])
seen = {}
for i in a + b:
    seen[i["number"]] = i
print(json.dumps(list(seen.values())))
')

    # For each candidate issue, extract deps and check status.
    # Recognizes:
    #   - inline phrases: "Blocked by: #N", "Waiting on #N", "Depends on #N"
    #   - section heading + bulleted #N references (the PO agent's standard format):
    #         ## Dependencies
    #         - #347 (standards doc)
    #         - #348 (audit)
    # A section that contains only "None" is treated as empty.
    local candidates
    candidates=$(ISS="$issues_json" python3 - <<'PY'
import json, os, re
issues = json.loads(os.environ['ISS'])

INLINE = re.compile(r'(?:blocked\s+by|waiting\s+on|depends\s+on)\s*[:\-]?\s*([^\n\r]+)', re.I)
SECTION = re.compile(
    r'^##\s*(?:dependencies|depends\s+on|blocked\s+by|waiting\s+on)\s*$([\s\S]*?)(?=^##\s|\Z)',
    re.I | re.M,
)
NUM = re.compile(r'#(\d+)')
NONE_LINE = re.compile(r'^\s*[-*]?\s*none\s*\.?\s*$', re.I | re.M)

for iss in issues:
    body = iss.get('body') or ''
    deps = set()
    # Inline phrases (legacy / non-PO-template issues)
    for m in INLINE.finditer(body):
        for n in NUM.findall(m.group(1)):
            deps.add(int(n))
    # ## Dependencies / ## Depends On / ## Blocked By / ## Waiting On — bullet sections
    for m in SECTION.finditer(body):
        section_body = m.group(1)
        if NONE_LINE.search(section_body):
            continue
        for n in NUM.findall(section_body):
            deps.add(int(n))
    # Self-references shouldn't count
    deps.discard(iss['number'])
    if not deps:
        continue
    labels = [l['name'] for l in iss.get('labels', [])]
    state = 'blocked' if 'blocked' in labels else 'needs-clarification'
    print(f"{iss['number']}\t{state}\t{','.join(str(n) for n in sorted(deps))}\t{iss['title'][:60]}")
PY
)

    if [ -z "$candidates" ]; then
        log "[$repo] no unblock candidates"
        return 0
    fi

    while IFS=$'\t' read -r num state deps title; do
        [ -z "$num" ] && continue
        # Check every referenced issue state
        local all_closed=true unresolved=""
        IFS=',' read -ra dep_arr <<< "$deps"
        for dep in "${dep_arr[@]}"; do
            local st
            st=$(backend_issue_view "$repo" "$dep" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
            if [ "$st" != "CLOSED" ]; then
                all_closed=false
                unresolved="${unresolved}#${dep} (${st}), "
            fi
        done
        if $all_closed; then
            log "[$repo] UNBLOCK issue #$num (${state}, deps ${deps} all closed): $title"
            loop_notify "Loop reconciler: $repo — unblocking #$num; deps (${deps}) all closed. Relabeling → dev."
            $DRY_RUN && continue
            backend_remove_label "$repo" "$num" "$state" \
                || log "[$repo] failed to relabel issue #$num"
            loop_notify_human_required_clear "${SLUG:-${repo##*/}}" "$num" "$state"
            backend_add_label "$repo" "$num" dev \
                || log "[$repo] failed to add dev label to issue #$num"
            backend_comment_issue "$repo" "$num" \
                "Reconciler: all declared dependencies (${deps}) are now closed. Relabeling \`${state}\` → \`dev\` so the pipeline retries." \
                || log "[$repo] failed to comment on issue #$num"
        else
            log "[$repo] issue #$num still blocked by: ${unresolved%, }"
        fi
    done <<< "$candidates"
}

# --- Check 7: orphaned worktrees (dev + rework) ----------------------------
# Scans /tmp/loop-worktree-${slug}-* and /tmp/loop-rework-${slug}-* for
# directories whose backing issue/PR is no longer OPEN. Removes orphans via
# git worktree remove --force with rm -rf fallback. Skips dirs modified in
# the last 10 minutes (handler may be mid-flight) and skips if project is
# locked. Uses python3 os.stat for portable mtime. Runs git worktree prune
# unconditionally at end (even in --dry-run).
reconcile_worktrees() {
    local slug="$1"
    local repo="$2"
    log "[$repo] scanning orphaned worktrees for slug=$slug"

    if project_locked "$slug"; then
        log "[$repo] project locked — skipping worktree reconciliation"
        return 0
    fi

    local now_sec
    now_sec=$(date +%s)
    local mtime_min=600  # 10 minutes in seconds

    local wt_dir base num mtime age state

    # Dev worktrees: /tmp/loop-worktree-<slug>-<issue_num>
    for wt_dir in /tmp/loop-worktree-"${slug}"-*/; do
        [ -d "$wt_dir" ] || continue
        wt_dir="${wt_dir%/}"
        base=$(basename "$wt_dir")
        num="${base#"loop-worktree-${slug}-"}"
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            log "[$repo] SKIP dev worktree $wt_dir — non-numeric suffix"
            continue
        fi
        mtime=$(python3 -c "import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))" "$wt_dir" 2>/dev/null || echo 0)
        age=$(( now_sec - mtime ))
        if [ "$age" -lt "$mtime_min" ]; then
            log "[$repo] SKIP dev worktree $wt_dir — recently modified (${age}s < ${mtime_min}s)"
            continue
        fi
        state=$(gh issue view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [ "$state" = "OPEN" ]; then
            continue
        fi
        log "[$repo] ORPHAN dev worktree $wt_dir (issue #$num state=$state)"
        loop_notify "Loop reconciler: $repo — removing orphaned dev worktree for issue #$num (state=$state)"
        $DRY_RUN && continue
        git -C "$ROOT" worktree remove "$wt_dir" --force 2>/dev/null \
            || rm -rf "$wt_dir"
    done

    # Rework worktrees: /tmp/loop-rework-<slug>-<pr_num>
    for wt_dir in /tmp/loop-rework-"${slug}"-*/; do
        [ -d "$wt_dir" ] || continue
        wt_dir="${wt_dir%/}"
        base=$(basename "$wt_dir")
        num="${base#"loop-rework-${slug}-"}"
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            log "[$repo] SKIP rework worktree $wt_dir — non-numeric suffix"
            continue
        fi
        mtime=$(python3 -c "import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))" "$wt_dir" 2>/dev/null || echo 0)
        age=$(( now_sec - mtime ))
        if [ "$age" -lt "$mtime_min" ]; then
            log "[$repo] SKIP rework worktree $wt_dir — recently modified (${age}s < ${mtime_min}s)"
            continue
        fi
        state=$(gh pr view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [ "$state" = "OPEN" ]; then
            continue
        fi
        log "[$repo] ORPHAN rework worktree $wt_dir (PR #$num state=$state)"
        loop_notify "Loop reconciler: $repo — removing orphaned rework worktree for PR #$num (state=$state)"
        $DRY_RUN && continue
        git -C "$ROOT" worktree remove "$wt_dir" --force 2>/dev/null \
            || rm -rf "$wt_dir"
    done

    log "[$repo] git worktree prune"
    git -C "$ROOT" worktree prune 2>/dev/null || true
}

# --- Check 8: lost issues (no pipeline label → route back to PO triage) -----
# Open issues that have no Loop pipeline label at all are invisible to the
# scanner and all handlers. Detect them and send back to the PO trigger so
# the PO agent can triage (re-spec, close, cancel, or upgrade to epic).
# Single source of truth: lib/labels.sh exports LOOP_PIPELINE_TRACKED_LABELS
# and the loop_pipeline_tracked_labels_string helper. Previously this was a
# hardcoded string here that drifted twice: missed needs-po/in-po/needs-dev/
# in-dev when the vocab migration landed in #167/#188, fixed in #207, now
# consolidated so any future label addition propagates from one place.
LOOP_PIPELINE_LABELS=$(loop_pipeline_tracked_labels_string)

reconcile_lost_issues() {
    # Observational, NOT mutating. Previously this function applied po-review
    # to any issue it considered "lost" — but that fought every other writer
    # within the same tick (alias-rename, synonym-rename, recovery_check_*,
    # etc.) and could be wrong on stale data (GitHub's read-after-write
    # consistency window for gh issue edit → gh issue list is non-zero).
    #
    # Concrete failure: today on example.com#10 the cycle was alias-rename
    # writes po-review → needs-po, lost-issues' next gh-fetch in the same
    # tick missed the update OR labels.sh's pipeline-label set was stale,
    # lost-issues re-applied po-review, alias-rename re-renamed, ...
    # 41+ comments, infinite ping-pong.
    #
    # Now: log + notify only. The operator (Signal) decides whether the
    # issue is genuinely abandoned vs. mid-transition. No mutation = no
    # tick-level coordination needed = no fights with other checks.
    local repo="$1"
    log "[$repo] scanning for lost issues (no pipeline label) — observational"

    local all_open_json
    all_open_json=$(gh issue list --repo "$repo" --state open --limit 200 --json number,title,labels 2>/dev/null || echo "[]")

    local lost
    lost=$(ISSUES="$all_open_json" LABELS="$LOOP_PIPELINE_LABELS" python3 - <<'PY'
import json, os
issues = json.loads(os.environ['ISSUES'])
known = set(os.environ['LABELS'].split())
for iss in issues:
    issue_labels = {l['name'] for l in iss.get('labels', [])}
    if not (issue_labels & known):
        print(f"{iss['number']}\t{iss['title'][:70]}")
PY
    )

    if [ -z "$lost" ]; then
        log "[$repo] no lost issues"
        return 0
    fi

    # Per-(repo,issue) cool-down so we don't spam Signal on every tick for
    # the same lost ticket. State file is touched once we've notified; the
    # next notification fires only after LOOP_LOST_NOTIFY_HOURS (default 24)
    # have elapsed.
    local cool_down_dir="${LOOP_LOST_STATE_DIR:-/tmp/loop-lost-notified}"
    local cool_down_hours="${LOOP_LOST_NOTIFY_HOURS:-24}"
    mkdir -p "$cool_down_dir"
    local cool_down_seconds=$(( cool_down_hours * 3600 ))
    local now_epoch
    now_epoch=$(date +%s)

    while IFS=$'\t' read -r num title; do
        [ -z "$num" ] && continue

        # Skip if the issue has an open PR closing it — work is on PR side
        # (#199 producer-side: dev-handler now strips the issue's trigger
        # label after opening the PR). Without this consumer-side gate,
        # operator gets a Signal for every healthy in-flight ticket.
        local _existing_pr
        _existing_pr=$(backend_find_pr_for_issue "$repo" "$num" 2>/dev/null || echo "")
        if [ -n "$_existing_pr" ]; then
            log "[$repo] LOST issue #$num — skipping Signal: open PR #${_existing_pr} closes it (work in flight, no operator action needed)"
            continue
        fi

        log "[$repo] LOST issue #$num (no pipeline label, no closing PR): $title — observational, no mutation"

        # Skip Signal if we already notified within the cool-down window.
        local repo_slug="${repo//\//-}"
        local sentinel="$cool_down_dir/${repo_slug}-${num}"
        if [ -f "$sentinel" ]; then
            local mtime; mtime=$(stat -c %Y "$sentinel" 2>/dev/null || stat -f %m "$sentinel" 2>/dev/null || echo 0)
            local age=$(( now_epoch - mtime ))
            if [ "$age" -lt "$cool_down_seconds" ]; then
                log "[$repo] LOST issue #$num — Signal cooled-down (last notified ${age}s ago)"
                continue
            fi
        fi

        $DRY_RUN && continue
        loop_notify "Loop reconciler: $repo — issue #$num has no pipeline label and no open PR closing it. Operator: pick a trigger label (e.g. \`po-review\` or \`dev\`) or close as out-of-scope. Title: ${title}"
        : > "$sentinel"
    done <<< "$lost"
}

# --- Check 9: required Loop labels (bootstrap + drift correction) ----------
# Ensures every repo in the pipeline has the full set of Loop labels.
# Creates any missing labels silently. This prevents handlers from failing to
# apply labels and leaving PRs/issues with no labels (a known stuck-pipeline
# failure mode when a repo is first onboarded without bootstrapping).
LOOP_REQUIRED_LABELS=(
    "${LOOP_LABEL_DEPRECATED_PO_REVIEW}:PO agent review queue:#1D76DB"
    "${LOOP_LABEL_DEPRECATED_DEV}:Automated dev cycle:#0075CA"
    "${LOOP_LABEL_DEPRECATED_IN_PROGRESS}:Currently being worked on:#FFA500"
    "${LOOP_LABEL_DEPRECATED_REVIEW_PENDING}:PR open, waiting for review:#9370DB"
    "${LOOP_LABEL_NEEDS_PO}:PO triage queue (canonical):#1D76DB"
    "${LOOP_LABEL_IN_PO}:PO triage in flight (canonical):#5DADE2"
    "${LOOP_LABEL_NEEDS_DEV}:Dev queue (canonical):#0075ca"
    "${LOOP_LABEL_IN_DEV}:Dev in flight (canonical):#FFA500"
    "${LOOP_LABEL_NEEDS_REVIEW}:Ready for human review:#0075ca"
    "${LOOP_LABEL_IN_REVIEW}:Review in progress:#6A5ACD"
    "${LOOP_LABEL_NEEDS_QA}:Review approved, pending QA:#FFD700"
    "${LOOP_LABEL_DEPRECATED_READY_FOR_QA}:Approved, needs QA:#FFD700"
    "${LOOP_LABEL_DEPRECATED_IN_REWORK}:Dev agent addressing reviewer feedback:#FFD700"
    "${LOOP_LABEL_DEPRECATED_NEEDS_REWORK}:Review rejected, dev must rework:#DC143C"
    "${LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED}:Reviewer requested changes:#FFA07A"
    "needs-clarification:Dev hit ambiguity:#FF69B4"
    "${LOOP_LABEL_BLOCKED}:Failed 3x, needs human:#8B0000"
    "${LOOP_LABEL_QA_FAIL}:QA failed, back to dev:#DC143C"
    "${LOOP_LABEL_QA_PASS}:QA passed, ready to merge:#32CD32"
    "${LOOP_LABEL_DONE}:Merged and closed:#006400"
)

reconcile_labels() {
    local repo="$1"
    log "[$repo] checking required Loop labels"
    local existing created=0
    existing=$(gh label list --repo "$repo" --limit 100 --json name --jq '.[].name' 2>/dev/null || echo "")
    for entry in "${LOOP_REQUIRED_LABELS[@]}"; do
        local name desc color
        name="${entry%%:*}"; rest="${entry#*:}"; desc="${rest%%:*}"; color="${rest##*:}"
        if ! echo "$existing" | grep -qxF "$name"; then
            log "[$repo] creating missing label: $name"
            $DRY_RUN && continue
            gh label create "$name" --repo "$repo" --description "$desc" --color "${color#\#}" 2>/dev/null \
                && created=$((created+1)) \
                || log "[$repo] WARN: failed to create label $name"
        fi
    done
    [ "$created" -gt 0 ] && loop_notify "Loop reconciler: $repo — created $created missing label(s)" || true
    log "[$repo] labels ok (created=$created)"
}

# --- Check 9b: rename synonym labels to live-workflow trigger names ----------
# Some review/QA/handler agents apply synonym labels that are not the live
# workflow trigger (e.g. `changes-requested` instead of `needs-rework`,
# `review-pending` instead of `needs-review`). The scanner only polls workflow
# triggers, so synonym-labelled tickets get stuck. Rename on sight.
#
# Map is intentionally narrow: only synonyms that can be safely promoted to
# the live default-workflow trigger names. The broader vocab unification
# (LOOP-167 / #165) is the canonical fix; this is the immediate stuck-ticket
# remedy.
LOOP_SYNONYM_MAP=(
    "review-pending:needs-review"
    "ready-for-qa:needs-qa"
    "changes-requested:needs-rework"
    "plan:dev"
)

_rename_label_on_target() {
    # _rename_label_on_target <repo> <number> <kind> <from> <to>
    # kind: issue | pr
    #
    # Two-step rename, ordered add-THEN-remove (#198 fix). If the add fails
    # (label not defined on repo, API rate limit, network flake), the
    # original `from` label is preserved so the ticket retains SOMETHING
    # the pipeline recognizes. The previous remove-then-add order could
    # leave a ticket label-less when add failed mid-batch (observed on
    # loop-monitor PRs #95/#88/#75, all empty-labelled simultaneously).
    local repo="$1" num="$2" kind="$3" from="$4" to="$5"
    if $DRY_RUN; then
        log "[$repo] DRY: would rename $kind #$num: $from → $to"
        return 0
    fi
    if ! backend_add_label "$repo" "$num" "$to"; then
        log "[$repo] WARN: rename $kind #$num: failed to add '$to' — keeping '$from'; will retry next tick"
        return 1
    fi
    backend_remove_label "$repo" "$num" "$from" \
        || log "[$repo] WARN: rename $kind #$num: failed to remove '$from' (target now has both labels; reconciler will retry the cleanup)"
    log "[$repo] renamed $kind #$num: $from → $to"
}

# _reconcile_label_renames <repo> <slug> <log_prefix> <pairs>
#
# Shared body for label-rewriting reconciler checks (#211). Iterates a
# newline-separated <pairs> list of "from:to" entries and renames each
# matching open issue / PR via the atomic _rename_label_on_target helper
# (add-then-remove, #198). Workflow-aware gate from lib/workflow.sh (#209)
# skips renames that would strip live triggers or apply dead labels.
#
# Two callers (kept as thin wrappers so log lines remain distinct and
# operators can tell synonym renames from alias renames at a glance):
#   - reconcile_synonym_labels  (LOOP_SYNONYM_MAP from reconciler.sh)
#   - reconcile_alias_renames   (LOOP_DEPRECATED_ALIAS_MAP via labels.sh)
_reconcile_label_renames() {
    local repo="$1" slug="$2" log_prefix="$3" pairs="$4"
    local renamed=0 from to

    while IFS=':' read -r from to; do
        [ -z "$from" ] || [ -z "$to" ] && continue
        # Self-mappings are no-ops (defensive — maps shouldn't contain them).
        [ "$from" = "$to" ] && continue

        for kind in issue pr; do
            if [ -n "$slug" ]; then
                if loop_label_is_trigger "$slug" "$kind" "$from"; then
                    log "[$repo] $log_prefix skip ($kind, $slug): '$from' is a workflow trigger here"
                    continue
                fi
                if ! loop_label_is_trigger "$slug" "$kind" "$to"; then
                    log "[$repo] $log_prefix skip ($kind, $slug): '$to' is not a workflow trigger here"
                    continue
                fi
            fi

            local items_json
            if [ "$kind" = "issue" ]; then
                items_json=$(backend_list_issues_with_label "$repo" "$from" 2>/dev/null || echo "")
            else
                items_json=$(backend_list_prs_with_label "$repo" "$from" 2>/dev/null || echo "")
            fi

            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local num
                num=$(printf '%s' "$line" | jq -r '.number // empty' 2>/dev/null)
                [ -z "$num" ] && continue
                _rename_label_on_target "$repo" "$num" "$kind" "$from" "$to"
                renamed=$((renamed + 1))
            done <<EOF
$items_json
EOF
        done
    done <<< "$pairs"

    echo "$renamed"
}

reconcile_synonym_labels() {
    local repo="$1" slug="${2:-}"
    log "[$repo] scanning open issues + PRs for synonym labels"
    local pairs
    pairs=$(printf '%s\n' "${LOOP_SYNONYM_MAP[@]}")
    local renamed
    renamed=$(_reconcile_label_renames "$repo" "$slug" "synonym" "$pairs")
    if [ "$renamed" -gt 0 ]; then
        log "[$repo] synonyms renamed: $renamed"
    fi
}

# --- Check: deprecated label aliases — rename to canonical ------------------
# Iterates every alias declared in LOOP_DEPRECATED_ALIAS_MAP (lib/labels.sh)
# and routes through _reconcile_label_renames. Now uses the atomic
# _rename_label_on_target helper (add-then-remove, #198) — previously this
# function had its own inline non-atomic remove-then-add (a #198 oversight
# that was a latent bug for current-workflow projects on every tick).
reconcile_alias_renames() {
    local repo="$1" slug="${2:-}"
    log "[$repo] scanning open issues + PRs for deprecated label aliases"

    # Build pairs ("alias:canonical") from the deprecated alias map.
    local pairs alias canonical
    pairs=""
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        canonical=$(loop_canonical_label "$alias")
        [ "$canonical" = "$alias" ] && continue
        pairs+="${alias}:${canonical}"$'\n'
    done < <(loop_deprecated_aliases)

    local renamed
    renamed=$(_reconcile_label_renames "$repo" "$slug" "alias-rename" "$pairs")
    log "[$repo] alias_renamed=$renamed"
}

# --- Check 10: orphaned in-progress issues (no live handler lock) --------------
# An issue stuck with `in-progress` but no live dev-handler or po-handler process
# will never self-recover — the EXIT trap added in the handlers handles normal
# crashes, but SIGKILL or a machine reboot can still leave these stranded.
# After a 10-minute grace window, reset to `dev` so the scanner re-queues it.
reconcile_orphaned_in_progress() {
    local repo="$1"
    local slug="$2"
    log "[$repo] scanning for orphaned in-progress issues (no live handler)"

    local issues_json
    issues_json=$(backend_list_open_issues_raw "$repo" "in-progress")

    local candidates
    candidates=$(ISS="$issues_json" python3 - <<'PY'
import json, os, datetime as dt
issues = json.loads(os.environ['ISS'])
now = dt.datetime.now(dt.timezone.utc)
for iss in issues:
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z', '+00:00'))
    age_s = (now - up).total_seconds()
    if age_s < 600:  # 10-min grace: handler may still be starting up
        continue
    print(f"{iss['number']}\t{int(age_s)}\t{iss['title'][:60]}")
PY
)

    if [ -z "$candidates" ]; then
        log "[$repo] no orphaned in-progress issues"
        return 0
    fi

    local lock_dir="${LOOP_LOCK_DIR:-/tmp/loop-locks}"
    local handler_alive lf pid

    while IFS=$'\t' read -r num age title; do
        [ -z "$num" ] && continue
        handler_alive=false
        for lf in "$lock_dir/${slug}-issue-${num}.lock" "$lock_dir/po-${slug}-${num}.lock"; do
            [ -f "$lf" ] || continue
            pid=$(cat "$lf" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                handler_alive=true; break
            fi
        done
        if $handler_alive; then
            log "[$repo] issue #$num in-progress with live handler (age=${age}s) — skip"
            continue
        fi
        log "[$repo] ORPHAN in-progress #$num (no live handler, ${age}s): $title"
        loop_notify "Loop reconciler: $repo — issue #$num orphaned in-progress (no handler, ${age}s); resetting to dev"
        $DRY_RUN && continue
        backend_remove_label "$repo" "$num" in-progress \
            || log "[$repo] WARN: failed to remove in-progress from #$num"
        backend_add_label "$repo" "$num" dev \
            || log "[$repo] WARN: failed to add dev to #$num"
    done <<< "$candidates"
}

# --- Check 12: QA failure recovery — transient auto-retry + repeated-failure clarification ---
# Default transient keywords. Operators can override via LOOP_TRANSIENT_KEYWORDS in loop.env.
# Value must be a comma-separated list of case-insensitive substrings to match against run logs.
_DEFAULT_TRANSIENT_KEYWORDS="timeout,rate limit,503,tcp i/o,ETIMEDOUT,connection refused,install"
QA_RETRY_STATE_DIR="/tmp/loop-qa-retry"

reconcile_qa_failures() {
    local repo="$1"
    log "[$repo] scanning qa-fail PRs for transient errors / repeated failures"

    mkdir -p "$QA_RETRY_STATE_DIR"

    # Fetch open PRs with qa-fail label
    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    local qa_fail_prs
    qa_fail_prs=$(PJSON="$prs_json" python3 - <<'PY'
import json, os
prs = json.loads(os.environ['PJSON'])
for pr in prs:
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    if 'qa-fail' in lbls:
        branch = pr.get('headRefName', '')
        print(f"{pr['number']}\t{branch}\t{pr.get('body','')[:400]}")
PY
)

    if [ -z "$qa_fail_prs" ]; then
        log "[$repo] no qa-fail PRs"
        return 0
    fi

    local transient_keywords="${LOOP_TRANSIENT_KEYWORDS:-$_DEFAULT_TRANSIENT_KEYWORDS}"
    # Sanitize repo name for use in file paths (no path traversal)
    local repo_safe="${repo//\//-}"
    repo_safe="${repo_safe//[^a-zA-Z0-9._-]/_}"

    while IFS=$'\t' read -r pr_num pr_branch pr_body; do
        [ -z "$pr_num" ] && continue

        # Marker file: capped at one auto-retry per PR per unique failure
        local marker="/tmp/loop-qa-retry-${repo_safe}-${pr_num}.retried"

        # Find the most recent failed QA run for this branch
        local run_id runs_raw
        runs_raw=$(gh run list --repo "$repo" \
            --workflow qa-build-test.yml \
            --json databaseId,conclusion,headBranch \
            --limit 20 2>/dev/null || echo "[]")
        run_id=$(RUNS="$runs_raw" BRANCH="$pr_branch" python3 - <<'PY2'
import json, os
rows = json.loads(os.environ['RUNS'])
branch = os.environ['BRANCH']
for r in rows:
    if r.get('headBranch') == branch and r.get('conclusion') in ('failure', 'timed_out'):
        print(r['databaseId'])
        break
PY2
) || run_id=""

        if [ -z "$run_id" ]; then
            log "[$repo] PR#$pr_num: no failed QA run found for branch=$pr_branch — skip"
            continue
        fi

        local run_log
        run_log=$(gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null || echo "")

        if [ -z "$run_log" ]; then
            log "[$repo] PR#$pr_num: empty QA run log for run=$run_id — skip"
            continue
        fi

        # Check for transient keywords
        local is_transient=false
        local kw
        IFS=',' read -ra kw_arr <<< "$transient_keywords"
        for kw in "${kw_arr[@]}"; do
            kw="${kw# }"; kw="${kw% }"
            if echo "$run_log" | grep -qi "$kw"; then
                is_transient=true
                break
            fi
        done

        if $is_transient && [ ! -f "$marker" ]; then
            log "[$repo] PR#$pr_num: transient QA failure detected (run=$run_id) — auto-retry"
            loop_notify "Loop reconciler: $repo — PR#$pr_num transient QA failure (run=$run_id); cycling qa-fail → needs-qa"
            $DRY_RUN && continue
            touch "$marker"
            backend_remove_label "$repo" "$pr_num" qa-fail \
                || log "[$repo] WARN: failed to remove qa-fail from PR#$pr_num"
            backend_add_label "$repo" "$pr_num" needs-qa \
                || log "[$repo] WARN: failed to add needs-qa to PR#$pr_num"
            continue
        fi

        # Retry already exhausted (marker exists) or non-transient: post clarification
        log "[$repo] PR#$pr_num: QA failure not auto-retryable (marker_exists=$( [ -f "$marker" ] && echo true || echo false ), transient=$is_transient) — posting clarification"

        # Extract failing test names (last 20 lines of log as context)
        local failing_tests last_20
        failing_tests=$(echo "$run_log" | grep -oE '(FAIL|FAILED|Error in|✗|×)[[:space:]]+[A-Za-z0-9_./:@ -]+' \
            | head -20 | sort -u | tr '\n' ' ' || echo "")
        last_20=$(echo "$run_log" | tail -20)

        # Extract linked issue numbers from PR body
        local linked_issues
        linked_issues=$(BODY="$pr_body" python3 - <<'PY3'
import re, os
nums = re.findall(r'[Cc]loses?\s+#(\d+)', os.environ.get('BODY', ''))
print(' '.join(nums))
PY3
)

        local clarification_body
        clarification_body="**What was tried:** QA workflow run [#${run_id}](https://github.com/${repo}/actions/runs/${run_id}) on PR #${pr_num} (branch \`${pr_branch}\`).

**What failed:**
\`\`\`
${failing_tests:-No structured test names found}
\`\`\`

<details><summary>Last 20 lines of failure output</summary>

\`\`\`
${last_20}
\`\`\`
</details>

**Options:**
(a) Fix the failing test(s) — update the code or test to make them pass, then push a new commit to this PR.
(b) Skip the test(s) — if the test is flaky or irrelevant to this change, annotate it with the appropriate skip marker and document why."

        $DRY_RUN && {
            log "[$repo] DRY_RUN: would post clarification comment on PR#$pr_num"
            continue
        }

        backend_comment_pr "$repo" "$pr_num" "$clarification_body" \
            || log "[$repo] WARN: failed to post clarification on PR#$pr_num"
        backend_add_label "$repo" "$pr_num" needs-clarification \
            || log "[$repo] WARN: failed to add needs-clarification to PR#$pr_num"

        # Also label the linked issue(s) with needs-clarification
        local issue_num
        for issue_num in $linked_issues; do
            backend_add_label "$repo" "$issue_num" needs-clarification \
                || log "[$repo] WARN: failed to add needs-clarification to issue#$issue_num"
            loop_notify_human_required "${SLUG:-${repo##*/}}" "$issue_num" needs-clarification \
                "QA failure on PR #${pr_num} escalated"
        done

        loop_notify "Loop reconciler: $repo — PR#$pr_num QA failure escalated to needs-clarification (run=$run_id)"
    done <<< "$qa_fail_prs"
}

# --- Check 11: conflict-blocked PRs — close + re-queue source issue to dev -----
# When the rework agent hits MAX_RETRIES because of a persistent rebase conflict,
# the PR ends up with `blocked` + mergeStateStatus=CONFLICTING/DIRTY. The branch
# is stale and the agent can't fix it — the cleanest recovery is to close the PR
# and send the source issue back to `dev` so a fresh branch is cut from current
# main (no conflicts). Runs every reconciler tick; safe to repeat (idempotent).
reconcile_conflict_blocked_prs() {
    local repo="$1"
    log "[$repo] scanning for conflict-blocked PRs to auto-recycle"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    # Find blocked PRs that are CONFLICTING or DIRTY
    local conflict_prs
    conflict_prs=$(PJSON="$prs_json" python3 - <<'PY'
import json, os
prs = json.loads(os.environ['PJSON'])
for pr in prs:
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    if 'blocked' not in lbls:
        continue
    # backend_list_open_prs_raw does not include mergeStateStatus; we flag by body pattern
    # The rework handler comments "Automated rework failed N times" before blocking.
    # We identify these by the blocked+draft combo — all rework-conflict PRs stay Draft.
    # Actual mergeability checked individually below via backend_pr_view.
    print(pr['number'])
PY
)

    [ -z "$conflict_prs" ] && { log "[$repo] no blocked PRs to check"; return 0; }

    local pr_num pr_state issue_nums issue_num
    for pr_num in $conflict_prs; do
        # Check actual merge state
        pr_state=$(backend_pr_view "$repo" "$pr_num" --json mergeStateStatus,body 2>/dev/null || echo "{}")
        local merge_status body
        merge_status=$(echo "$pr_state" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergeStateStatus',''))" 2>/dev/null || echo "")
        body=$(echo "$pr_state" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('body',''))" 2>/dev/null || echo "")

        case "$merge_status" in
            CONFLICTING|DIRTY) : ;;
            *) log "[$repo] PR #$pr_num blocked but merge_status=$merge_status — skip auto-recycle"; continue ;;
        esac

        # Parse linked issues from "Closes #N"
        issue_nums=$(echo "$body" | python3 -c "
import re, sys
print(' '.join(re.findall(r'[Cc]loses?\s+#(\d+)', sys.stdin.read() or '')))" 2>/dev/null || echo "")

        log "[$repo] auto-recycle: PR #$pr_num conflict-blocked (merge_status=$merge_status) linked_issues='$issue_nums'"
        $DRY_RUN && continue

        backend_comment_pr "$repo" "$pr_num" \
            "Reconciler: PR has a persistent rebase conflict that automated rework could not resolve. Closing and re-queuing the source issue(s) (\`$issue_nums\`) back to \`dev\` for a fresh branch from current main." \
            2>/dev/null || true
        backend_close_pr "$repo" "$pr_num" 2>/dev/null || true

        for issue_num in $issue_nums; do
            backend_remove_label "$repo" "$issue_num" blocked qa-pass "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" "$LOOP_LABEL_DEPRECATED_IN_REWORK" 2>/dev/null || true
            backend_add_label "$repo" "$issue_num" dev 2>/dev/null || true
            log "[$repo] re-queued issue #$issue_num → dev (Opus dispatch)"
            # Dispatch directly with Opus — re-labeling to dev would just let Sonnet fail again.
            local iss_event
            iss_event=$(python3 -c "import json; print(json.dumps({'type':'loop.dev_issue','payload':{'slug':'${slug}','repo':'${repo}','issue_number':'${issue_num}','issue_title':''}}))" 2>/dev/null || true)
            if [ -n "$iss_event" ]; then
                LOOP_AGENT_MODEL=claude-opus-4-7 LOOP_EVENT_JSON="$iss_event" \
                    nohup timeout "${HANDLER_TIMEOUT_SECONDS:-3600}" \
                    "$LOOP_ROOT/scripts/dev-handler.sh" \
                    >> "$LOOP_LOG_DIR/loop-dev-handler.log" 2>&1 &
                log "[$repo] Opus dev-handler dispatched for issue #$issue_num (PID $!)"
            fi
        done

        # If no Closes link found, just log — don't close with no re-queue plan
        if [ -z "$issue_nums" ]; then
            log "[$repo] WARN: PR #$pr_num has no Closes link — closed but no issue re-queued"
        fi
    done
}

# --- Check 12: auto-rebase PRs with stale base (rework / qa-fail) --------------
# For PRs labeled with the rework trigger or qa-fail, detect if the PR branch has diverged
# from origin/<DEFAULT_BRANCH>. If so, attempt a clean git rebase. On success,
# push with --force-with-lease and re-trigger the pipeline stage label. On
# conflict, abort and log a warning — never auto-resolve non-trivial conflicts.
# Respects DRY_RUN: detects divergence but skips push and label mutations.
reconcile_stale_base() {
    local repo="$1"
    log "[$repo] checking for PRs with stale base (needs-rework / qa-fail)"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    # Filter to PRs with needs-rework or qa-fail; emit: pr_num TAB head_ref TAB active_label
    local target_prs
    target_prs=$(PJSON="$prs_json" python3 - <<'PY'
import json, os
prs = json.loads(os.environ['PJSON'])
for pr in prs:
    lbls = {l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])}
    if 'needs-rework' not in lbls and 'qa-fail' not in lbls:
        continue
    head = pr.get('headRefName', '')
    if not head:
        continue
    active = 'qa-fail' if 'qa-fail' in lbls else 'needs-rework'
    print(f"{pr['number']}\t{head}\t{active}")
PY
)

    if [ -z "$target_prs" ]; then
        log "[$repo] no needs-rework/qa-fail PRs found"
        return 0
    fi

    # Resolve a local git dir: GIT_WORK_DIR → ROOT → scratch clone
    local _git_dir="" _tmp_clone=""
    if [ -n "${GIT_WORK_DIR:-}" ] && git -C "${GIT_WORK_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        _git_dir="${GIT_WORK_DIR}"
    elif [ -n "${ROOT:-}" ] && [ -d "${ROOT}" ] && git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        _git_dir="${ROOT}"
    else
        _tmp_clone=$(mktemp -d)
        log "[$repo] no local clone configured; scratch-cloning into ${_tmp_clone}"
        if ! gh repo clone "$repo" "${_tmp_clone}" -- --quiet 2>/dev/null; then
            log "[$repo] WARN: failed to clone repo; skipping stale-base check"
            rm -rf "${_tmp_clone}"
            return 0
        fi
        _git_dir="${_tmp_clone}"
    fi

    # Fetch latest origin (and unshallow if needed so merge-base has full history)
    git -C "$_git_dir" fetch origin --quiet 2>/dev/null \
        || log "[$repo] WARN: git fetch failed; divergence checks may be stale"
    if git -C "$_git_dir" rev-parse --is-shallow-repository 2>/dev/null | grep -q "^true$"; then
        git -C "$_git_dir" fetch --unshallow --quiet 2>/dev/null || true
    fi

    local pr_num head_ref active_label _wt_dir
    while IFS=$'\t' read -r pr_num head_ref active_label; do
        [ -z "$pr_num" ] && continue

        # Safety: never operate on the default branch
        if [ "$head_ref" = "$DEFAULT_BRANCH" ]; then
            log "[$repo] PR#$pr_num: head is default branch ($DEFAULT_BRANCH) — skip"
            continue
        fi

        # Fetch PR branch into a remote tracking ref so we can reference it by name
        if ! git -C "$_git_dir" fetch origin \
                "${head_ref}:refs/remotes/origin/${head_ref}" --quiet 2>/dev/null; then
            log "[$repo] WARN: PR#$pr_num — cannot fetch branch ${head_ref}; skipping"
            continue
        fi

        # Detect divergence: is origin/<DEFAULT_BRANCH> an ancestor of the PR branch?
        # Returns 0 (up-to-date, skip) or non-zero (diverged, needs rebase).
        if git -C "$_git_dir" merge-base --is-ancestor \
                "origin/${DEFAULT_BRANCH}" "origin/${head_ref}" 2>/dev/null; then
            log "[$repo] PR#$pr_num (${head_ref}) base is current — no action"
            continue
        fi

        log "[$repo] PR#$pr_num (${head_ref}) base has diverged from origin/${DEFAULT_BRANCH}"

        if $DRY_RUN; then
            log "[$repo] DRY_RUN: would rebase ${head_ref} onto origin/${DEFAULT_BRANCH}"
            continue
        fi

        # Create a temp worktree at the PR branch tip for the rebase
        _wt_dir=$(mktemp -d) || { log "[$repo] WARN: PR#$pr_num — mktemp failed; skipping"; continue; }
        rmdir "$_wt_dir"
        if ! git -C "$_git_dir" worktree add --detach \
                "$_wt_dir" "origin/${head_ref}" 2>/dev/null; then
            log "[$repo] WARN: PR#$pr_num — could not create worktree; skipping"
            continue
        fi

        if git -C "$_wt_dir" rebase "origin/${DEFAULT_BRANCH}" 2>/dev/null; then
            # Push rebased branch back — always with --force-with-lease, never to default branch
            if git -C "$_wt_dir" push origin \
                    "HEAD:refs/heads/${head_ref}" --force-with-lease --quiet 2>/dev/null; then
                log "[$repo] PR#$pr_num (${head_ref}): rebased onto ${DEFAULT_BRANCH} and pushed"
                loop_notify "Loop reconciler: $repo — PR#$pr_num auto-rebased ${head_ref} onto ${DEFAULT_BRANCH}"
                # Re-trigger the pipeline stage via label cycle
                if [ "$active_label" = "qa-fail" ]; then
                    backend_remove_label "$repo" "$pr_num" needs-qa || true
                    backend_add_label    "$repo" "$pr_num" needs-qa || true
                else
                    backend_remove_label "$repo" "$pr_num" needs-rework || true
                    backend_add_label    "$repo" "$pr_num" needs-rework || true
                fi
            else
                log "[$repo] WARN: PR#$pr_num — rebase clean but push failed (concurrent update?)"
            fi
        else
            git -C "$_wt_dir" rebase --abort 2>/dev/null || true
            log "[$repo] PR#$pr_num (${head_ref}): rebase has conflicts — aborting, PR unchanged"
            loop_notify "Loop reconciler: $repo — PR#$pr_num (${head_ref}) rebase conflict; manual fix needed"
        fi

        git -C "$_git_dir" worktree remove "$_wt_dir" --force 2>/dev/null \
            || rm -rf "$_wt_dir"
    done <<< "$target_prs"

    git -C "$_git_dir" worktree prune 2>/dev/null || true
    if [ -n "$_tmp_clone" ]; then
        rm -rf "$_tmp_clone"
    fi
    return 0  # explicit — guard against trailing-conditional set -e hazard (#212)
}

# --- Check 13: stale blocked issues — Opus escalation after 30 min -----------
# Issues that have been `blocked` for more than 30 minutes with no live handler
# are automatically re-dispatched using Opus. Covers: issues blocked by the PO
# agent, dev agent, or manually — anything that Sonnet couldn't resolve.
# Idempotent: a fresh dispatch will claim in-progress, so subsequent ticks skip.
reconcile_stale_blocked_issues() {
    local repo="$1"
    log "[$repo] scanning for stale blocked issues (>30m) to Opus-escalate"

    local issues_json
    issues_json=$(backend_list_open_issues_raw "$repo" "blocked") || issues_json="[]"

    local candidates
    candidates=$(ISS="$issues_json" python3 - <<'PY'
import json, os, datetime as dt
issues = json.loads(os.environ['ISS'])
now = dt.datetime.now(dt.timezone.utc)
for iss in issues:
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z', '+00:00'))
    age_s = int((now - up).total_seconds())
    if age_s < 1800:   # 30-min grace: might have just been blocked
        continue
    print(f"{iss['number']}\t{age_s}\t{iss['title'][:60]}")
PY
)

    if [ -z "$candidates" ]; then
        log "[$repo] no stale blocked issues"
        return 0
    fi

    while IFS=$'\t' read -r num age title; do
        [ -z "$num" ] && continue
        log "[$repo] stale-blocked issue #$num (${age}s): $title — Opus escalation"
        $DRY_RUN && continue

        backend_remove_label "$repo" "$num" blocked 2>/dev/null || true
        backend_add_label "$repo" "$num" dev 2>/dev/null || true

        local iss_event
        iss_event=$(python3 -c "import json; print(json.dumps({'type':'loop.dev_issue','payload':{'slug':'${slug}','repo':'${repo}','issue_number':'${num}','issue_title':''}}))" 2>/dev/null || true)
        if [ -n "$iss_event" ]; then
            LOOP_AGENT_MODEL=claude-opus-4-7 LOOP_EVENT_JSON="$iss_event" \
                nohup timeout "${HANDLER_TIMEOUT_SECONDS:-3600}" \
                "$LOOP_ROOT/scripts/dev-handler.sh" \
                >> "$LOOP_LOG_DIR/loop-dev-handler.log" 2>&1 &
            log "[$repo] Opus dev-handler dispatched for blocked issue #$num (PID $!)"
        fi
        loop_notify "Loop reconciler: $repo — stale blocked issue #$num escalated to Opus (age=${age}s)"
    done <<< "$candidates"
}

# --- Check 14: DIRTY rework PRs — skip rework, recycle immediately with Opus --
# A PR in the rework queue (deprecated rework-trigger aliases) that is already
# CONFLICTING/DIRTY will make the rework agent fail immediately — it can't fix
# conflicts. Instead of waiting for 2 rework failures + a block, detect this
# proactively and recycle now.
reconcile_dirty_rework_prs() {
    local repo="$1"
    log "[$repo] scanning rework PRs for DIRTY/CONFLICTING state"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    local rework_prs
    rework_prs=$(PJSON="$prs_json" \
        LBL_CR="$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" \
        LBL_NR="$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" \
        python3 - <<'PY'
import json, os, datetime as dt
prs = json.loads(os.environ['PJSON'])
now = dt.datetime.now(dt.timezone.utc)
LBL_CR = os.environ['LBL_CR']
LBL_NR = os.environ['LBL_NR']
for pr in prs:
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    if LBL_CR not in lbls and LBL_NR not in lbls:
        continue
    if 'blocked' in lbls:
        continue  # already handled by Check 11/13
    # Grace: skip if updated <15min ago (rework handler mid-flight)
    up = dt.datetime.fromisoformat(pr.get('updatedAt','').replace('Z','+00:00')) if pr.get('updatedAt') else now
    if (now - up).total_seconds() < 900:
        continue
    print(pr['number'])
PY
)

    [ -z "$rework_prs" ] && { log "[$repo] no rework PRs to check"; return 0; }

    local pr_num pr_state merge_status body issue_nums issue_num
    for pr_num in $rework_prs; do
        pr_state=$(backend_pr_view "$repo" "$pr_num" --json mergeStateStatus,body 2>/dev/null || echo "{}")
        merge_status=$(echo "$pr_state" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergeStateStatus',''))" 2>/dev/null || echo "")
        case "$merge_status" in
            CONFLICTING|DIRTY) : ;;
            *) continue ;;
        esac
        body=$(echo "$pr_state" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('body',''))" 2>/dev/null || echo "")
        issue_nums=$(echo "$body" | python3 -c "
import re,sys; print(' '.join(re.findall(r'[Cc]loses?\s+#(\d+)', sys.stdin.read() or '')))" 2>/dev/null || echo "")

        log "[$repo] DIRTY rework PR #$pr_num (merge_status=$merge_status) — recycling with Opus linked=$issue_nums"
        $DRY_RUN && continue

        backend_comment_pr "$repo" "$pr_num" \
            "Reconciler: PR is CONFLICTING/DIRTY — rework would fail immediately. Closing and re-queuing issue(s) \`$issue_nums\` for a fresh Opus branch from current main." \
            2>/dev/null || true
        backend_close_pr "$repo" "$pr_num" 2>/dev/null || true

        for issue_num in $issue_nums; do
            backend_remove_label "$repo" "$issue_num" blocked "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" "$LOOP_LABEL_DEPRECATED_IN_REWORK" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" 2>/dev/null || true
            backend_add_label "$repo" "$issue_num" dev 2>/dev/null || true
            local iss_event
            iss_event=$(python3 -c "import json; print(json.dumps({'type':'loop.dev_issue','payload':{'slug':'${slug}','repo':'${repo}','issue_number':'${issue_num}','issue_title':''}}))" 2>/dev/null || true)
            if [ -n "$iss_event" ]; then
                LOOP_AGENT_MODEL=claude-opus-4-7 LOOP_EVENT_JSON="$iss_event" \
                    nohup timeout "${HANDLER_TIMEOUT_SECONDS:-3600}" \
                    "$LOOP_ROOT/scripts/dev-handler.sh" \
                    >> "$LOOP_LOG_DIR/loop-dev-handler.log" 2>&1 &
                log "[$repo] Opus dev-handler dispatched for issue #$issue_num from dirty-rework recycle (PID $!)"
            fi
        done
        [ -z "$issue_nums" ] && log "[$repo] WARN: DIRTY rework PR #$pr_num has no Closes link"
    done
}

# --- Check 15: stale pipeline labels on closed issues (issue #166) ---------
# When an issue is closed (manually or by a closing comment) without a merged
# PR, its pipeline-stage labels are not stripped. Leaves the dashboard with
# false positives like "closed issues that are still needs-clarification".
# Walks recently-closed issues and strips every pipeline-stage label.
# Orthogonal labels (priority, semver:*, epic, tracker, etc.) are preserved.
# Idempotent: a second pass finds nothing to do.
LOOP_CLOSED_LOOKBACK_DAYS="${LOOP_CLOSED_LOOKBACK_DAYS:-7}"

reconcile_closed_issue_labels() {
    local repo="$1"
    log "[$repo] scanning closed issues (last ${LOOP_CLOSED_LOOKBACK_DAYS}d) for stale pipeline labels"

    local since
    since=$(python3 -c "import datetime as d; print((d.datetime.utcnow()-d.timedelta(days=int(${LOOP_CLOSED_LOOKBACK_DAYS}))).strftime('%Y-%m-%d'))")

    local closed_json
    closed_json=$(gh issue list --repo "$repo" --state closed \
        --search "closed:>=${since}" \
        --limit 200 --json number,title,labels 2>/dev/null || echo "[]")

    local stale
    stale=$(ISS="$closed_json" STAGE="$(loop_pipeline_stage_labels_csv)" python3 - <<'PY'
import json, os
issues = json.loads(os.environ['ISS'])
stage = set(os.environ['STAGE'].split(','))
for iss in issues:
    labels = {l['name'] for l in iss.get('labels', [])}
    bad = labels & stage
    if bad:
        print(f"{iss['number']}\t{','.join(sorted(bad))}\t{iss['title'][:60]}")
PY
)

    if [ -z "$stale" ]; then
        log "[$repo] no closed issues with stale pipeline labels"
        return 0
    fi

    local num bad title
    while IFS=$'\t' read -r num bad title; do
        [ -z "$num" ] && continue
        log "[$repo] STALE-LABELS closed issue #$num (strip: $bad): $title"
        $DRY_RUN && continue
        loop_strip_pipeline_labels "$repo" "$num" "$bad" >/dev/null || true
    done <<< "$stale"
}

# --- Check: qa-rework label drift — strip stale needs-qa from rework PRs ---
# Belt-and-suspenders sweep: if a PR carries both needs-qa (or its deprecated
# alias ready-for-qa) AND a rework trigger label (in-rework, needs-dev,
# needs-rework, changes-requested), the producer already missed stripping
# needs-qa. Remove it here so the scanner doesn't emit conflicting
# pr_qa + dev_rework events on the next tick.
reconcile_qa_rework_label_drift() {
    local repo="$1"
    log "[$repo] scanning for PRs with stale needs-qa + rework label"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo")

    local hits
    hits=$(PRS="$prs_json" python3 - <<'PY'
import json, os
QA_LABELS     = {"needs-qa", "ready-for-qa"}
REWORK_LABELS = {"in-rework", "needs-dev", "needs-rework", "changes-requested"}
prs = json.loads(os.environ["PRS"])
for pr in prs:
    labels = {l["name"] for l in pr.get("labels", [])}
    qa_present     = labels & QA_LABELS
    rework_present = labels & REWORK_LABELS
    if qa_present and rework_present:
        print("{}\t{}".format(pr["number"], ",".join(sorted(qa_present))))
PY
)

    if [ -z "$hits" ]; then
        log "[$repo] no qa-rework label drift found"
        return 0
    fi

    local num stale_qa
    while IFS=$'\t' read -r num stale_qa; do
        [ -z "$num" ] && continue
        log "[$repo] QA-REWORK-DRIFT PR#$num strip stale qa label(s): $stale_qa"
        $DRY_RUN && continue
        local label
        local IFS_ORIG="$IFS"
        IFS=','
        for label in $stale_qa; do
            backend_remove_label "$repo" "$num" "$label" >/dev/null 2>&1 || true
        done
        IFS="$IFS_ORIG"
    done <<< "$hits"
}

# --- Check: PR label audit — strip issue-only labels from open PRs ---------
# Pipeline-trigger labels (`needs-po`, `needs-dev`, plus deprecated aliases)
# and taxonomy labels (`tracker`, `epic`, `needs-clarification`) belong on
# issues only. If applied to a PR by mistake, scanner/handler logic may
# misfire. For each open PR carrying any issue-only label, strip the labels
# and post one combined comment per PR per run.
reconcile_pr_label_audit() {
    local repo="$1"
    log "[$repo] auditing open PRs for issue-only labels"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo")

    local hits
    hits=$(PRS="$prs_json" ISSUE_ONLY="$(loop_issue_only_labels_csv)" python3 - <<'PY'
import json, os
prs = json.loads(os.environ['PRS'])
issue_only = set(os.environ['ISSUE_ONLY'].split(','))
for pr in prs:
    labels = {l['name'] for l in pr.get('labels', [])}
    bad = labels & issue_only
    if bad:
        print(f"{pr['number']}\t{','.join(sorted(bad))}")
PY
)

    if [ -z "$hits" ]; then
        log "[$repo] no PRs carrying issue-only labels"
        return 0
    fi

    local num bad
    while IFS=$'\t' read -r num bad; do
        [ -z "$num" ] && continue
        log "[$repo] PR-LABEL-AUDIT PR#$num strip issue-only: $bad"
        if $DRY_RUN; then
            continue
        fi
        local label
        local IFS_ORIG="$IFS"
        IFS=','
        for label in $bad; do
            backend_remove_label "$repo" "$num" "$label" >/dev/null 2>&1 || true
        done
        IFS="$IFS_ORIG"
        backend_comment_pr "$repo" "$num" \
            "Reconciler: removed issue-only label(s): ${bad}. These trigger issue-side handlers and can misfire on PRs."
    done <<< "$hits"
}

# --- Check: anomaly detector — surface ping-pong / starvation tickets ----
# Closes #195. Deterministic check that mines the reconciler's own log file
# for label-flip-rate anomalies. When a single ticket appears in N or more
# touch events within a window, Signal the operator once (cool-down per
# ticket) so they can investigate before the ticket consumes more cycles.
#
# Mined patterns: alias-rename, synonym, UNBLOCK, LOST (post-#214 logged
# but not auto-routed) — every reconciler check that *touches* a ticket.
#
# Configurable env:
#   LOOP_ANOMALY_THRESHOLD     default 4   (touches in window → anomalous)
#   LOOP_ANOMALY_WINDOW_HOURS  default 1
#   LOOP_ANOMALY_NOTIFY_HOURS  default 24  (per-ticket Signal cool-down)
#   LOOP_ANOMALY_STATE_DIR     default /tmp/loop-anomaly-notified
reconcile_anomalies() {
    local repo="$1"
    log "[$repo] anomaly detector: scanning recent reconciler activity"

    local threshold="${LOOP_ANOMALY_THRESHOLD:-4}"
    local window_hours="${LOOP_ANOMALY_WINDOW_HOURS:-1}"
    local notify_hours="${LOOP_ANOMALY_NOTIFY_HOURS:-24}"
    local state_dir="${LOOP_ANOMALY_STATE_DIR:-/tmp/loop-anomaly-notified}"
    mkdir -p "$state_dir"

    [ -f "$LOG_FILE" ] || { log "[$repo] no reconciler log to mine"; return 0; }

    # Mine the reconciler log: count touch-events per ticket within the
    # window, emit "<num>\t<count>" for tickets crossing the threshold.
    REPO_FOR_PY="$repo" THRESHOLD="$threshold" WIN_HOURS="$window_hours" \
    LOG_FILE_PY="$LOG_FILE" python3 - <<'PY' | while IFS=$'\t' read -r num touches; do
import os, re, sys, time
from datetime import datetime

repo = os.environ['REPO_FOR_PY']
threshold = int(os.environ['THRESHOLD'])
window_seconds = int(os.environ['WIN_HOURS']) * 3600
cutoff = time.time() - window_seconds

ts_re   = re.compile(r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')
repo_tag = f'[{repo}]'
# Touch patterns this detector recognises:
touch_re = re.compile(
    r'(alias-rename (?:issue|PR) #\d+)'
    r'|(synonym[^#]*#\d+)'
    r'|(UNBLOCK (?:issue|PR) #\d+)'
    r'|(LOST issue #\d+)'
)
num_re = re.compile(r'#(\d+)')
counts = {}

try:
    with open(os.environ['LOG_FILE_PY'], 'r', errors='replace') as f:
        for line in f:
            tm = ts_re.match(line)
            if tm:
                try:
                    epoch = datetime.strptime(tm.group(1), '%Y-%m-%d %H:%M:%S').timestamp()
                except ValueError:
                    continue
                if epoch < cutoff:
                    continue
            else:
                continue
            if repo_tag not in line:
                continue
            if not touch_re.search(line):
                continue
            m = num_re.search(line)
            if m:
                counts[m.group(1)] = counts.get(m.group(1), 0) + 1
except FileNotFoundError:
    sys.exit(0)

for num, count in counts.items():
    if count >= threshold:
        print(f"{num}\t{count}")
PY
        [ -z "$num" ] && continue
        local repo_slug="${repo//\//-}"
        local sentinel="$state_dir/${repo_slug}-${num}"
        local cool_down_seconds=$(( notify_hours * 3600 ))
        local now_epoch; now_epoch=$(date +%s)

        if [ -f "$sentinel" ]; then
            local mtime; mtime=$(stat -c %Y "$sentinel" 2>/dev/null || stat -f %m "$sentinel" 2>/dev/null || echo 0)
            local age=$(( now_epoch - mtime ))
            if [ "$age" -lt "$cool_down_seconds" ]; then
                log "[$repo] anomaly: #$num touches=$touches in ${window_hours}h — Signal cooled-down (${age}s ago)"
                continue
            fi
        fi

        log "[$repo] ANOMALY: #$num — $touches reconciler touches in last ${window_hours}h (threshold=$threshold)"
        $DRY_RUN && continue
        loop_notify "Loop reconciler: $repo — issue/PR #$num was touched ${touches}× in the last ${window_hours}h. Likely a pipeline pathology (ping-pong, eventual-consistency drift, missing label, etc.). Operator: investigate. URL: https://github.com/${repo}/issues/${num}" \
            || true
        : > "$sentinel"
    done

    return 0
}

# --- Check: agent self-diagnosis — surface meta-bug language in comments -----
# Closes #203. Agents (PO/dev/review/qa) sometimes write meta-bug language in
# their own PR/issue comments — "reconciler keeps stripping", "human action
# required", etc. The anomaly detector (#195) catches BEHAVIOR (label flip
# rate); this check catches NARRATIVE.
#
# Mines comments authored by ALLOWED_AUTHORS (agents post as the operator),
# bounded to tickets updated in the last LOOP_DISTRESS_WINDOW hours.
#
# Configurable env:
#   LOOP_DISTRESS_WINDOW_HOURS   default 1
#   LOOP_DISTRESS_NOTIFY_HOURS   default 24  (per-ticket cool-down)
#   LOOP_DISTRESS_STATE_DIR      default /tmp/loop-distress-notified
#   LOOP_DISTRESS_PHRASES_FILE   optional path to a custom phrase list
#                                (one regex per line; defaults built-in)
reconcile_agent_distress() {
    local repo="$1"
    log "[$repo] agent-distress detector: scanning recent comments"

    local window_hours="${LOOP_DISTRESS_WINDOW_HOURS:-1}"
    local notify_hours="${LOOP_DISTRESS_NOTIFY_HOURS:-24}"
    local state_dir="${LOOP_DISTRESS_STATE_DIR:-/tmp/loop-distress-notified}"
    local phrases_file="${LOOP_DISTRESS_PHRASES_FILE:-}"
    mkdir -p "$state_dir"

    local default_phrases='reconciler keeps
reconciler is.*looping
pipeline is.*looping
human action required
no progress (after|since)
[0-9]+\+? cycles
ping[ -]?pong
pathology
stuck cycle
operator: investigate
manually fix the reconciler'

    local phrases
    if [ -n "$phrases_file" ] && [ -f "$phrases_file" ]; then
        phrases=$(cat "$phrases_file")
    else
        phrases="$default_phrases"
    fi

    local since
    since=$(date -u -v "-${window_hours}H" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || date -u -d "${window_hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || echo "")
    [ -z "$since" ] && { log "[$repo] agent-distress: cannot compute window cutoff"; return 0; }

    local recent_json
    recent_json=$(gh search issues --repo "$repo" --updated ">=$since" --state open \
                  --limit 50 --json number 2>/dev/null || echo "[]")
    local recent_nums
    recent_nums=$(printf '%s' "$recent_json" | jq -r '.[].number // empty' 2>/dev/null || echo "")
    [ -z "$recent_nums" ] && { log "[$repo] agent-distress: no recently-updated tickets"; return 0; }

    local now_epoch; now_epoch=$(date +%s)
    local cool_down_seconds=$(( notify_hours * 3600 ))

    local num
    for num in $recent_nums; do
        local comments_json
        comments_json=$(gh issue view "$num" --repo "$repo" --json comments 2>/dev/null \
                        || echo "{\"comments\":[]}")

        local matched
        matched=$(PHRASES="$phrases" AUTHORS="${ALLOWED_AUTHORS:-svv2014}" \
                  python3 -c '
import json, os, re, sys
data = json.load(sys.stdin)
authors = set(os.environ["AUTHORS"].split(","))
patterns = [re.compile(p, re.IGNORECASE) for p in os.environ["PHRASES"].splitlines() if p.strip()]
for c in data.get("comments", [])[-10:]:
    author = (c.get("author") or {}).get("login", "")
    if author not in authors:
        continue
    body = c.get("body") or ""
    for p in patterns:
        m = p.search(body)
        if m:
            print(m.group(0)[:80])
            sys.exit(0)
' <<< "$comments_json" 2>/dev/null || echo "")

        [ -z "$matched" ] && continue

        local repo_slug="${repo//\//-}"
        local sentinel="$state_dir/${repo_slug}-${num}"
        if [ -f "$sentinel" ]; then
            local mtime; mtime=$(stat -c %Y "$sentinel" 2>/dev/null || stat -f %m "$sentinel" 2>/dev/null || echo 0)
            local age=$(( now_epoch - mtime ))
            if [ "$age" -lt "$cool_down_seconds" ]; then
                log "[$repo] agent-distress: #$num matched '$matched' — Signal cooled-down (${age}s ago)"
                continue
            fi
        fi

        log "[$repo] AGENT-DISTRESS: #$num — agent comment matched '$matched'"
        $DRY_RUN && continue
        loop_notify "Loop reconciler: $repo — agent posted distress on #$num: '$matched'. Likely pipeline pathology the agent recognises but cannot fix. Operator: investigate. URL: https://github.com/${repo}/issues/${num}" \
            || true
        : > "$sentinel"
    done

    return 0
}

# --- Helper: resolve effective loop branch regex ------------------------------
# Returns the regex used to identify loop-opened PR head branches.
#
# Resolution order:
#   1. LOOP_BRANCH_PREFIX (legacy) — if set, emit `^<escaped-prefix>(\d+)-`.
#      Capture group 1 is the issue number. Kept for backward compatibility.
#   2. LOOP_BRANCH_PATTERN — full regex; default matches feat|fix|chore|docs.
#      Default: `^(?:feat|fix|chore|docs)/issue-(\d+)-`. Capture group 1 is
#      the issue number.
_loop_branch_pattern() {
    if [ -n "${LOOP_BRANCH_PREFIX:-}" ]; then
        PREFIX="$LOOP_BRANCH_PREFIX" python3 -c 'import os, re; print("^" + re.escape(os.environ["PREFIX"]) + r"(\d+)-")'
    else
        printf '%s\n' "${LOOP_BRANCH_PATTERN:-^(?:feat|fix|chore|docs)/issue-(\d+)-}"
    fi
}

# --- Check: CI red on loop-opened PRs → auto-apply needs-rework ---------------
# Scans open PRs whose head branch matches the loop branch convention
# (feat|fix|chore|docs)/issue-N-*. For each, queries `gh pr checks` to look
# for required checks in FAILURE state. If found, and the PR has no human
# review and no needs-rework label already, applies needs-rework to the PR
# and strips the parent issue's trigger label (needs-dev / in-dev) so the
# scanner stops re-claiming it. Emits a pr_ci_failed event to loop-monitor.
#
# No-op conditions (checked before any mutation):
#   - PR already has needs-rework or changes-requested label
#   - PR has at least one human APPROVED or CHANGES_REQUESTED review
#   - dev.auto_rework_on_ci is false in projects.yaml for this project
#
# Configurable env (all optional):
#   AUTO_REWORK_ON_CI      — set to "false" to disable per-project (default: true)
#   LOOP_BRANCH_PATTERN    — branch regex (default: ^(?:feat|fix|chore|docs)/issue-(\d+)-)
#   LOOP_BRANCH_PREFIX     — legacy single-prefix shortcut (overrides PATTERN if set)
reconcile_ci_red_prs() {
    local repo="$1"
    local branch_pattern
    branch_pattern=$(_loop_branch_pattern)

    # Per-project opt-out via dev.auto_rework_on_ci: false in projects.yaml.
    if [ "${AUTO_REWORK_ON_CI:-true}" = "false" ]; then
        log "[$repo] CI-rework: disabled via AUTO_REWORK_ON_CI=false — skipping"
        return 0
    fi

    log "[$repo] CI-rework: scanning loop-opened PRs for red CI"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    # Filter to PRs whose head branch matches the loop convention.
    local loop_prs
    loop_prs=$(PJSON="$prs_json" PATTERN="$branch_pattern" python3 - <<'PY'
import json, os, re
prs = json.loads(os.environ['PJSON'])
pat = re.compile(os.environ['PATTERN'])
for pr in prs:
    head = pr.get('headRefName', '')
    m = pat.match(head)
    if not m:
        continue
    issue_num = m.group(1)
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    # NOTE: do NOT emit PR body — bodies contain newlines which would split the
    # `while IFS=$'\t' read` loop into one iteration per body line, causing each
    # markdown line (`### Changes`, `- foo.md`, etc.) to be treated as a PR number.
    print(f"{pr['number']}\t{head}\t{issue_num}\t{','.join(lbls)}")
PY
)

    if [ -z "$loop_prs" ]; then
        log "[$repo] CI-rework: no loop-opened PRs found"
        return 0
    fi

    local pr_num head_ref issue_num labels_csv
    while IFS=$'\t' read -r pr_num head_ref issue_num labels_csv; do
        [ -z "$pr_num" ] && continue

        # Skip if PR already has needs-rework or changes-requested (already handled).
        if echo "$labels_csv" | grep -qE '(needs-rework|changes-requested)'; then
            log "[$repo] CI-rework: PR#$pr_num already has needs-rework/changes-requested — skip"
            continue
        fi

        # Skip if PR has any human review (APPROVED or CHANGES_REQUESTED).
        local review_state
        review_state=$(gh pr view "$pr_num" --repo "$repo" \
            --json reviews --jq '[.reviews[].state] | map(select(. == "APPROVED" or . == "CHANGES_REQUESTED")) | length' \
            2>/dev/null || echo "0")
        if [ "${review_state:-0}" -gt 0 ]; then
            log "[$repo] CI-rework: PR#$pr_num has human review (state=$review_state) — skip"
            continue
        fi

        # Query CI checks for this PR.
        local checks_json
        checks_json=$(gh pr checks "$pr_num" --repo "$repo" --json name,state,required \
            2>/dev/null || echo "[]")

        # Detect any required check in FAILURE state.
        local has_failure
        has_failure=$(CHECKS="$checks_json" python3 - <<'PY2'
import json, os
checks = json.loads(os.environ['CHECKS'])
for c in checks:
    # gh pr checks --json uses 'state' field with value 'FAILURE' for failed checks.
    # 'required' is a bool; treat absent as False.
    if c.get('required') and c.get('state', '').upper() in ('FAILURE', 'FAILED'):
        print('yes')
        break
PY2
)

        if [ "$has_failure" != "yes" ]; then
            log "[$repo] CI-rework: PR#$pr_num — no required check failures"
            continue
        fi

        log "[$repo] CI-rework: PR#$pr_num (branch=$head_ref) has required CI failure — applying needs-rework"
        loop_notify "Loop reconciler: $repo — PR#$pr_num (${head_ref}) has red required CI; applying needs-rework to issue #${issue_num}"

        if $DRY_RUN; then
            log "[$repo] DRY_RUN: would apply needs-rework to PR#$pr_num and strip trigger label from issue #$issue_num"
            continue
        fi

        # Apply needs-rework to the PR.
        backend_add_label "$repo" "$pr_num" needs-rework \
            || log "[$repo] WARN: CI-rework: failed to add needs-rework to PR#$pr_num"

        # Strip trigger label(s) from the parent issue so the scanner doesn't re-claim.
        local trigger_label
        for trigger_label in needs-dev in-dev dev in-progress; do
            backend_remove_label "$repo" "$issue_num" "$trigger_label" 2>/dev/null || true
        done

        # Post a comment on the PR explaining the auto-rework.
        local failing_checks
        failing_checks=$(CHECKS="$checks_json" python3 - <<'PY3'
import json, os
checks = json.loads(os.environ['CHECKS'])
names = [c['name'] for c in checks if c.get('required') and c.get('state','').upper() in ('FAILURE','FAILED')]
print(', '.join(names) if names else 'unknown')
PY3
)
        backend_comment_pr "$repo" "$pr_num" \
            "Reconciler: required CI check(s) failed (\`${failing_checks}\`). Applying \`needs-rework\` so the dev agent can address the failures. Stripped trigger label from issue #${issue_num}." \
            2>/dev/null || true

        # Emit pr_ci_failed event to loop-monitor (fire-and-forget; non-fatal if absent).
        local monitor_url="${LOOP_MONITOR_URL:-}"
        if [ -n "$monitor_url" ]; then
            local event_payload
            event_payload=$(python3 -c "
import json, sys
print(json.dumps({'type':'pr_ci_failed','payload':{'repo':'${repo}','pr_number':${pr_num},'issue_number':${issue_num},'branch':'${head_ref}','failing_checks':'${failing_checks}'}}))" 2>/dev/null || echo "")
            if [ -n "$event_payload" ]; then
                curl -s -X POST "$monitor_url/events" \
                    -H 'Content-Type: application/json' \
                    -d "$event_payload" >/dev/null 2>&1 || true
            fi
        fi

        log "[$repo] CI-rework: done — PR#$pr_num → needs-rework, issue #$issue_num trigger stripped"
    done <<< "$loop_prs"
}

# reconcile_ci_green_prs <repo> [slug]
#
# For each loop-opened PR (branch matches LOOP_BRANCH_PATTERN) whose required
# CI checks are all SUCCESS and which still carries needs-dev, promote it to
# the project's review-stage trigger label (default: needs-review) and emit
# a pr_ci_passed event. This closes the "green CI but PR sits indefinitely"
# gap without requiring a human to manually trigger review.
#
# No-op conditions (checked before any mutation):
#   - PR already has needs-review, changes-requested, or needs-rework
#   - PR does not have needs-dev
#   - PR has at least one human review (APPROVED, CHANGES_REQUESTED, or COMMENTED)
#     from an author not in ALLOWED_AUTHORS
#   - Any required check is not SUCCESS (PENDING/IN_PROGRESS/EXPECTED/FAILURE etc.)
#   - No required checks and PR is not MERGEABLE (guard for unconfigured repos)
#   - AUTO_PROMOTE_ON_CI is set to "false"
#
# Configurable env (all optional):
#   AUTO_PROMOTE_ON_CI     — set to "false" to disable per-project (default: true)
#   LOOP_BRANCH_PATTERN    — branch regex (default: ^(?:feat|fix|chore|docs)/issue-(\d+)-)
#   LOOP_BRANCH_PREFIX     — legacy single-prefix shortcut (overrides PATTERN if set)
reconcile_ci_green_prs() {
    local repo="$1"
    local slug="${2:-}"
    local branch_pattern
    branch_pattern=$(_loop_branch_pattern)

    # Per-project opt-out via AUTO_PROMOTE_ON_CI=false (or dev.auto_promote_on_ci
    # in projects.yaml set as an env var before calling this function).
    if [ "${AUTO_PROMOTE_ON_CI:-true}" = "false" ]; then
        log "[$repo] CI-promote: disabled via AUTO_PROMOTE_ON_CI=false — skipping"
        return 0
    fi

    log "[$repo] CI-promote: scanning loop-opened PRs for green CI"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    # Filter to PRs whose head branch matches the loop convention.
    local loop_prs
    loop_prs=$(PJSON="$prs_json" PATTERN="$branch_pattern" python3 - <<'PY'
import json, os, re
prs = json.loads(os.environ['PJSON'])
pat = re.compile(os.environ['PATTERN'])
for pr in prs:
    head = pr.get('headRefName', '')
    m = pat.match(head)
    if not m:
        continue
    issue_num = m.group(1)
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    # NOTE: do NOT emit PR body — bodies contain newlines which would split the
    # `while IFS=$'\t' read` loop into one iteration per body line, causing each
    # markdown line (`### Changes`, `- foo.md`, etc.) to be treated as a PR number.
    print(f"{pr['number']}\t{head}\t{issue_num}\t{','.join(lbls)}")
PY
)

    if [ -z "$loop_prs" ]; then
        log "[$repo] CI-promote: no loop-opened PRs found"
        return 0
    fi

    local pr_num head_ref issue_num labels_csv
    while IFS=$'\t' read -r pr_num head_ref issue_num labels_csv; do
        [ -z "$pr_num" ] && continue

        # PR must have needs-dev to be a promotion candidate.
        if ! echo "$labels_csv" | grep -q 'needs-dev'; then
            log "[$repo] CI-promote: PR#$pr_num lacks needs-dev — skip"
            continue
        fi

        # Skip if PR already has needs-review, changes-requested, or needs-rework.
        if echo "$labels_csv" | grep -qE '(needs-review|changes-requested|needs-rework)'; then
            log "[$repo] CI-promote: PR#$pr_num already has review/rework label — skip"
            continue
        fi

        # Fetch PR details: CI status rollup, latest reviews, labels, mergeability.
        local pr_detail
        pr_detail=$(backend_pr_view "$repo" "$pr_num" \
            --json statusCheckRollup,latestReviews,labels,mergeable \
            2>/dev/null || echo "")

        if [ -z "$pr_detail" ]; then
            log "[$repo] CI-promote: PR#$pr_num — failed to fetch PR detail — skip"
            continue
        fi

        # Evaluate CI checks and human reviews in one Python pass.
        local promote_verdict
        promote_verdict=$(DETAIL="$pr_detail" ALLOWED="${ALLOWED_AUTHORS:-}" python3 - <<'PY2'
import json, os
detail = json.loads(os.environ['DETAIL'])
allowed = set(a.strip() for a in os.environ.get('ALLOWED', '').split(',') if a.strip())

# Check latestReviews for human reviews (any non-bot reviewer).
for review in detail.get('latestReviews', []):
    state = review.get('state', '')
    author_login = (review.get('author') or {}).get('login', '')
    if state in ('APPROVED', 'CHANGES_REQUESTED', 'COMMENTED') and author_login not in allowed:
        print('human_review')
        raise SystemExit(0)

# Evaluate statusCheckRollup.
rollup = detail.get('statusCheckRollup', [])
mergeable = detail.get('mergeable', '')

if not rollup:
    # No checks configured: promote only if GitHub considers the PR mergeable.
    if mergeable == 'MERGEABLE':
        print('all_green')
    else:
        print('no_checks_not_mergeable')
    raise SystemExit(0)

required_checks = [c for c in rollup if c.get('isRequired')]
if not required_checks:
    # Checks present but none marked required: be conservative, require mergeable.
    if mergeable == 'MERGEABLE':
        print('all_green')
    else:
        print('no_required')
    raise SystemExit(0)

for c in required_checks:
    state = (c.get('state') or c.get('conclusion') or '').upper()
    if state in ('FAILURE', 'FAILED', 'ERROR', 'TIMED_OUT', 'ACTION_REQUIRED'):
        print('failure')
        raise SystemExit(0)
    if state != 'SUCCESS':
        # PENDING, IN_PROGRESS, EXPECTED, QUEUED, NEUTRAL, SKIPPED, STALE, etc.
        print('pending')
        raise SystemExit(0)

print('all_green')
PY2
)

        if [ "$promote_verdict" != "all_green" ]; then
            log "[$repo] CI-promote: PR#$pr_num — verdict=$promote_verdict — skip"
            continue
        fi

        log "[$repo] CI-promote: PR#$pr_num (branch=$head_ref) all required CI green — promoting to review"
        loop_notify "Loop reconciler: $repo — PR#$pr_num (${head_ref}) CI all green; promoting to review (issue #${issue_num})"

        if $DRY_RUN; then
            log "[$repo] DRY_RUN: would promote PR#$pr_num to review, issue #$issue_num"
            continue
        fi

        # Resolve the review-stage trigger label for this project's active workflow.
        local review_label
        review_label=$(loop_stage_trigger "${slug:-}" "review" "pr" 2>/dev/null || echo "")
        [ -z "$review_label" ] && review_label="needs-review"

        # Transition: remove needs-dev, add review trigger label.
        backend_remove_label "$repo" "$pr_num" needs-dev \
            || log "[$repo] WARN: CI-promote: failed to remove needs-dev from PR#$pr_num"
        backend_add_label "$repo" "$pr_num" "$review_label" \
            || log "[$repo] WARN: CI-promote: failed to add $review_label to PR#$pr_num"

        # Emit pr_ci_passed event to loop-monitor (fire-and-forget; non-fatal if absent).
        local monitor_url="${LOOP_MONITOR_URL:-}"
        if [ -n "$monitor_url" ]; then
            local event_payload
            event_payload=$(python3 -c "
import json
print(json.dumps({'type':'pr_ci_passed','payload':{'repo':'${repo}','pr_number':${pr_num},'issue_number':${issue_num},'branch':'${head_ref}'}}))" 2>/dev/null || echo "")
            if [ -n "$event_payload" ]; then
                curl -s -X POST "$monitor_url/events" \
                    -H 'Content-Type: application/json' \
                    -d "$event_payload" >/dev/null 2>&1 || true
            fi
        fi

        log "[$repo] CI-promote: done — PR#$pr_num → $review_label, needs-dev removed"
    done <<< "$loop_prs"
}

# Helper: post a JSON event to loop-monitor (fire-and-forget; non-fatal).
# Usage: _loop_emit_event <event_type> <json_payload_string>
_loop_emit_event() {
    local event_type="$1" payload="$2"
    local monitor_url="${LOOP_MONITOR_URL:-}"
    [ -n "$monitor_url" ] || return 0
    local body
    body=$(python3 -c "
import json, sys
try:
    p = json.loads(sys.argv[1])
    print(json.dumps({'type': sys.argv[2], 'payload': p}))
except Exception:
    pass" "$payload" "$event_type" 2>/dev/null || echo "")
    [ -n "$body" ] || return 0
    curl -s -X POST "$monitor_url/events" \
        -H 'Content-Type: application/json' \
        -d "$body" >/dev/null 2>&1 || true
}

# _reconcile_rebase_one_pr <repo> <pr_num> <base> <head>
#
# Performs an isolated git rebase of <head> onto origin/<base> in a temp
# worktree rooted under LOOP_ROOT. Prints conflicted file list to stdout
# before returning 3 so the caller can assemble the diagnostic comment.
#
# Return codes:
#   0 — clean rebase and force-with-lease push succeeded
#   1 — fetch or worktree-add failed (transient; skip, no label mutation)
#   2 — push --force-with-lease rejected (concurrent update; skip)
#   3 — rebase conflict; stdout has newline-separated conflicted file paths
#
# NOTE: git worktree remove --force can fail when the worktree is still dirty
# after rebase --abort (git refuses to remove a worktree with untracked files
# in some versions). The trap falls back to rm -rf; git worktree prune on the
# next reconciler tick will remove the stale entry from .git/worktrees.
_reconcile_rebase_one_pr() {
    local repo="$1" pr_num="$2" base="$3" head="$4"
    # ROOT is set by loop_load_project at the per-project reconciler entry
    # point and points at the target project's local clone. LOOP_ROOT is the
    # loop checkout itself and cannot fetch refs from a different repo (#384).
    local repo_root="${ROOT:-$LOOP_ROOT}"
    local wt
    wt=$(mktemp -d "/tmp/loop-rebase-${repo//\//-}-${pr_num}-XXXXXX")
    # shellcheck disable=SC2064
    trap "git -C '$repo_root' worktree remove --force '$wt' 2>/dev/null || true; rm -rf '$wt'" RETURN
    git -C "$repo_root" fetch --quiet origin "$base" "$head" || return 1
    git -C "$repo_root" worktree add --quiet "$wt" "origin/$head" || return 1
    if git -C "$wt" rebase --quiet "origin/$base"; then
        git -C "$wt" push --force-with-lease origin "HEAD:$head" || return 2
        return 0
    else
        local conflicted
        conflicted=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || echo "")
        git -C "$wt" rebase --abort 2>/dev/null || true
        printf '%s\n' "$conflicted"
        return 3
    fi
}

# --- Sweep: auto-rebase loop PRs when base branch has advanced ----------------
# Scans open loop-opened PRs (matched by LOOP_BRANCH_PATTERN) whose mergeStateStatus is DIRTY
# or mergeable is CONFLICTING. For each, attempts an isolated git rebase onto
# origin/<base>. Clean rebases are pushed with --force-with-lease so CI
# re-runs and Sweep 1 (reconcile_ci_green_prs) can promote them. Conflicting
# rebases route the PR back to needs-rework with a diagnostic comment listing
# each conflicted file and the most recent base commit that touched it.
#
# No-op conditions (checked before any git operation):
#   - PR already carries needs-rework, changes-requested, or blocked
#   - PR has at least one human review (APPROVED or CHANGES_REQUESTED)
#   - AUTO_REBASE_ON_BASE_MOVE=false
#
# This sweep does NOT change labels on a clean rebase — CI re-running and
# promotion are out-of-band consequences handled by other sweeps.
#
# Configurable env (all optional):
#   AUTO_REBASE_ON_BASE_MOVE — set to "false" to disable per-project (default: true)
#   LOOP_BRANCH_PATTERN      — branch regex (default: ^(?:feat|fix|chore|docs)/issue-(\d+)-)
#   LOOP_BRANCH_PREFIX       — legacy single-prefix shortcut (overrides PATTERN if set)
reconcile_pr_base_moved() {
    local repo="$1" slug="${2:-}"
    local branch_pattern
    branch_pattern=$(_loop_branch_pattern)

    if [ "${AUTO_REBASE_ON_BASE_MOVE:-true}" = "false" ]; then
        log "[$repo] base-move: disabled via AUTO_REBASE_ON_BASE_MOVE=false — skipping"
        return 0
    fi

    log "[$repo] base-move: scanning loop-opened PRs for base divergence"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    # Filter to loop-opened PRs; skip those already in terminal rework states.
    # Emits: pr_num TAB head_ref TAB issue_num TAB labels_csv TAB pr_body(400)
    local loop_prs
    loop_prs=$(PJSON="$prs_json" PATTERN="$branch_pattern" python3 - <<'PY'
import json, os, re
prs = json.loads(os.environ['PJSON'])
pat = re.compile(os.environ['PATTERN'])
skip_set = {'needs-rework', 'changes-requested', 'blocked'}
for pr in prs:
    head = pr.get('headRefName', '')
    m = pat.match(head)
    if not m:
        continue
    issue_num = m.group(1)
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    if skip_set & set(lbls):
        continue
    # NOTE: do NOT emit PR body — bodies contain newlines which would split the
    # `while IFS=$'\t' read` loop into one iteration per body line, causing each
    # markdown line (`### Changes`, `- foo.md`, etc.) to be treated as a PR number.
    print(f"{pr['number']}\t{head}\t{issue_num}\t{','.join(lbls)}")
PY
)

    if [ -z "$loop_prs" ]; then
        log "[$repo] base-move: no eligible loop-opened PRs"
        return 0
    fi

    local pr_num head_ref issue_num labels_csv
    while IFS=$'\t' read -r pr_num head_ref issue_num labels_csv; do
        [ -z "$pr_num" ] && continue

        # Query per-PR merge state and reviews in one backend call.
        local pr_state
        pr_state=$(backend_pr_view "$repo" "$pr_num" \
            --json mergeStateStatus,mergeable,baseRefName,latestReviews \
            2>/dev/null || echo "{}")

        local merge_status mergeable base_ref review_count
        merge_status=$(printf '%s' "$pr_state" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('mergeStateStatus',''))" \
            2>/dev/null || echo "")
        mergeable=$(printf '%s' "$pr_state" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('mergeable',''))" \
            2>/dev/null || echo "")
        base_ref=$(printf '%s' "$pr_state" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('baseRefName','main'))" \
            2>/dev/null || echo "main")
        review_count=$(printf '%s' "$pr_state" | python3 -c "
import json, sys
d = json.load(sys.stdin)
reviews = d.get('latestReviews', []) or []
human = [r for r in reviews if r.get('state') in ('APPROVED', 'CHANGES_REQUESTED')]
print(len(human))" 2>/dev/null || echo "0")

        # Skip unless base has moved (DIRTY or CONFLICTING merge state).
        case "${merge_status}:${mergeable}" in
            DIRTY:*|*:CONFLICTING) : ;;
            *)
                log "[$repo] base-move: PR#$pr_num mergeState=$merge_status mergeable=$mergeable — not diverged, skip"
                continue
                ;;
        esac

        # Skip if a human has reviewed — don't auto-modify a reviewed PR.
        if [ "${review_count:-0}" -gt 0 ]; then
            log "[$repo] base-move: PR#$pr_num has human review (count=$review_count) — skip"
            continue
        fi

        log "[$repo] base-move: PR#$pr_num ($head_ref → origin/$base_ref) is diverged — attempting rebase"

        if $DRY_RUN; then
            log "[$repo] DRY_RUN: would rebase PR#$pr_num ($head_ref) onto origin/$base_ref"
            continue
        fi

        local rebase_out rebase_ret
        rebase_out=$(_reconcile_rebase_one_pr "$repo" "$pr_num" "$base_ref" "$head_ref") \
            && rebase_ret=0 || rebase_ret=$?

        case "$rebase_ret" in
            0)
                log "[$repo] rebased PR #$pr_num cleanly onto origin/$base_ref"
                _loop_emit_event "pr_rebased" \
                    "{\"repo\":\"$repo\",\"pr_num\":$pr_num,\"issue_num\":$issue_num,\"base\":\"$base_ref\",\"head\":\"$head_ref\"}" \
                    || true
                ;;
            3)
                local conflicted_files="$rebase_out"
                log "[$repo] base-move: PR#$pr_num rebase conflict — routing to needs-rework"

                # Build diagnostic comment with most recent base commit per file.
                local comment_lines
                comment_lines=$(
                    printf 'Reconciler: auto-rebase onto `origin/%s` failed with conflicts. Routing to `needs-rework`.\n\nConflicted files:\n' "$base_ref"
                    while IFS= read -r cfile; do
                        [ -z "$cfile" ] && continue
                        local recent
                        recent=$(git -C "$LOOP_ROOT" log --pretty='%h %s' \
                            "origin/$base_ref" -10 -- "$cfile" 2>/dev/null | head -1 || echo "")
                        printf -- '- `%s` — recent base commit: `%s`\n' \
                            "$cfile" "${recent:-(unknown)}"
                    done <<< "$conflicted_files"
                )
                backend_comment_pr "$repo" "$pr_num" "$comment_lines" 2>/dev/null || true

                # Resolve rework trigger label for this project's workflow.
                local rework_label
                rework_label=$(loop_stage_trigger "$slug" "rework" "pr" 2>/dev/null \
                    || echo "needs-rework")
                [ -n "$rework_label" ] || rework_label="needs-rework"

                backend_add_label "$repo" "$pr_num" "$rework_label" \
                    || log "[$repo] WARN: base-move: failed to add $rework_label to PR#$pr_num"

                # Strip trigger labels from the parent issue.
                local trig_label
                for trig_label in needs-dev in-dev dev in-progress; do
                    backend_remove_label "$repo" "$issue_num" "$trig_label" 2>/dev/null || true
                done

                # Emit conflict event.
                local files_json
                files_json=$(printf '%s\n' "$conflicted_files" | python3 -c \
                    "import json,sys; files=[l for l in sys.stdin.read().splitlines() if l]; print(json.dumps(files))" \
                    2>/dev/null || echo "[]")
                _loop_emit_event "pr_rebase_conflict" \
                    "{\"repo\":\"$repo\",\"pr_num\":$pr_num,\"issue_num\":$issue_num,\"conflicted_files\":$files_json}" \
                    || true
                ;;
            1|2)
                log "[$repo] base-move: PR#$pr_num transient git error (ret=$rebase_ret) — skipping, will retry next tick"
                ;;
        esac
    done <<< "$loop_prs"

    return 0
}

# --- Sweep: auto-label fully-unlabelled open issues with needs-po -------------
# Operator-filed issues sometimes land in a repo without any pipeline label —
# they have a priority tag at best, sometimes nothing. The scanner skips them
# silently because nothing triggers, and the operator has to label every issue
# by hand to get them into the pipeline. This sweep promotes those orphans to
# `needs-po` so the PO handler picks them up on the next tick.
#
# Conservative by design:
#   - skip issues that already carry any workflow trigger label
#   - skip terminal/holding labels (needs-clarification, blocked, done)
#   - skip epic / tracker tickets (umbrella issues, not actionable themselves)
#   - skip issues whose author is outside ALLOWED_AUTHORS (unless operator-
#     approved) — same author gate the scanner already enforces
#   - opt-out via LOOP_AUTO_NEEDS_PO=false
reconcile_orphan_issues() {
    local repo="$1" slug="$2"

    if [ "${LOOP_AUTO_NEEDS_PO:-true}" = "false" ]; then
        return 0
    fi

    log "[$repo] scanning for orphan issues without pipeline labels"

    local issues_json
    issues_json=$(gh issue list --repo "$repo" --state open --limit 200 \
        --json number,title,labels,author 2>/dev/null || echo "[]")

    # Pre-fetch open PR bodies once so we can skip issues that already have an
    # open PR claiming to close them. Without this guard, dev-handler's
    # post-PR cleanup (removes `needs-dev` from the issue) leaves the issue
    # with no pipeline label → this function re-labels it `needs-po` → PO
    # runs again → dev opens another PR → reconcile_duplicate_prs closes the
    # older one → infinite po → dev → po loop (svv2014/loop#312).
    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo" 2>/dev/null || echo "[]")

    local orphans
    orphans=$(ALLOWED="${ALLOWED_AUTHORS:-}" ISSUES="$issues_json" PRS="$prs_json" python3 - <<'PY'
import json, os, re
allowed_raw = os.environ.get('ALLOWED', '').strip()
allowed = {a.strip() for a in allowed_raw.split(',') if a.strip()}
issues = json.loads(os.environ.get('ISSUES') or '[]')
prs = json.loads(os.environ.get('PRS') or '[]')

TRIGGERS = {
    'needs-po', 'in-po', 'po-review',
    'dev', 'plan', 'needs-dev', 'in-progress',
}
TERMINALS = {'needs-clarification', 'blocked', 'done'}
SKIP_KIND = {'epic', 'tracker'}

# Build the set of issue numbers that have at least one open PR closing them.
_LINK_RE = re.compile(r'(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\s+#(\d+)', re.I)
linked = set()
for pr in prs:
    for n in _LINK_RE.findall(pr.get('body') or ''):
        try:
            linked.add(int(n))
        except (TypeError, ValueError):
            pass

for it in issues:
    num = it.get('number')
    if num is None:
        continue
    if num in linked:
        # An open PR already references this issue — pipeline is in flight,
        # not orphaned. Skip.
        continue
    labels = {
        (l.get('name') if isinstance(l, dict) else l)
        for l in (it.get('labels') or [])
    }
    if labels & TRIGGERS:
        continue
    if labels & TERMINALS:
        continue
    if labels & SKIP_KIND:
        continue
    if allowed:
        author_obj = it.get('author') or {}
        author = author_obj.get('login') or author_obj.get('name') or ''
        if author and author not in allowed and 'operator-approved' not in labels:
            continue
    title = (it.get('title') or '').replace('\n', ' ').strip()[:80]
    print(f"{num}\t{title}")
PY
    )

    if [ -z "$orphans" ]; then
        log "[$repo] no orphan issues found"
        return 0
    fi

    while IFS=$'\t' read -r num title; do
        [ -z "$num" ] && continue
        if $DRY_RUN; then
            log "[$repo] DRY: would add needs-po to orphan issue #$num: $title"
            continue
        fi
        log "[$repo] auto-label needs-po: orphan issue #$num: $title"
        backend_add_label "$repo" "$num" "needs-po"
        _loop_emit_event "auto_labeled_needs_po" \
            "{\"repo\":\"$repo\",\"slug\":\"$slug\",\"issue_num\":$num}" \
            || true
    done <<< "$orphans"

    return 0
}

# --- Sweep: converge conflicting label sets to workflow-legal combinations ---
# Stage handlers each touch a narrow set of labels and occasionally leave a
# ticket in a workflow-illegal combination — e.g. a PR with both `qa-pass`
# AND `needs-dev` (qa passed but the rework signal stayed on), or a PR with
# `qa-fail` but no `needs-rework` (failed QA, no rework trigger). These
# combinations confuse the next handler: sometimes the wrong role claims,
# sometimes nothing claims and the ticket stalls.
#
# This sweep enforces per-stage exclusivity rules so the label state always
# represents a single workflow stage.
#
# PR rules:
#   qa-pass                    → strip needs-dev, needs-review, needs-rework,
#                                changes-requested, qa-fail, in-review, in-rework
#   qa-fail | changes-requested → ensure needs-rework; strip qa-pass, needs-review
#   needs-review               → never co-exists with needs-dev / needs-rework /
#                                changes-requested (prefer rework, drop needs-review)
#   ready-for-qa               → strip needs-review, needs-dev
#
# Issue rules:
#   needs-dev → strip needs-po, in-po, po-review, plan
#   needs-po  → strip needs-dev, in-progress, dev
#   blocked   → terminal — strip all trigger labels
#
# Opt-out:  LOOP_LABEL_CONVERGE=false
# DRY_RUN honored (logs intended mutations, no API calls).
reconcile_label_consistency() {
    local repo="$1" slug="$2"

    if [ "${LOOP_LABEL_CONVERGE:-true}" = "false" ]; then
        return 0
    fi

    log "[$repo] label-state convergence sweep"

    local prs_json issues_json
    prs_json=$(backend_list_open_prs_raw "$repo" 2>/dev/null || echo "[]")
    issues_json=$(gh issue list --repo "$repo" --state open --limit 200 \
        --json number,labels 2>/dev/null || echo "[]")

    local plan
    plan=$(PRS="$prs_json" ISSUES="$issues_json" python3 - <<'PY'
import json, os

prs = json.loads(os.environ.get('PRS') or '[]')
issues = json.loads(os.environ.get('ISSUES') or '[]')

PR_TRIGGERS_ON_QA_PASS = [
    'needs-dev', 'needs-review', 'needs-rework',
    'changes-requested', 'qa-fail', 'in-review', 'in-rework',
]
ISSUE_TRIGGERS_BLOCKED = [
    'needs-po', 'in-po', 'po-review', 'plan',
    'needs-dev', 'in-progress', 'dev',
    'needs-review', 'needs-rework', 'changes-requested',
    'ready-for-qa', 'in-review', 'in-rework',
]

def names(item):
    return {
        (l.get('name') if isinstance(l, dict) else l)
        for l in (item.get('labels') or [])
    }

def emit(kind, num, adds, removes):
    if not adds and not removes:
        return
    # Use '-' as placeholder so bash read doesn't collapse empty tab fields
    # (bash's read collapses consecutive whitespace-IFS delimiters).
    print('\t'.join([
        kind, str(num),
        ','.join(sorted(adds)) or '-',
        ','.join(sorted(removes)) or '-',
    ]))

for pr in prs:
    num = pr.get('number')
    if num is None:
        continue
    labels = names(pr)
    adds, removes = set(), set()

    if 'qa-pass' in labels:
        for l in PR_TRIGGERS_ON_QA_PASS:
            if l in labels:
                removes.add(l)

    rework_signal = ('qa-fail' in labels) or ('changes-requested' in labels)
    if rework_signal:
        if 'needs-rework' not in labels:
            adds.add('needs-rework')
        for l in ('qa-pass', 'needs-review'):
            if l in labels:
                removes.add(l)

    # needs-review must not co-exist with dev/rework signals; prefer rework.
    if 'needs-review' in labels and not rework_signal:
        if labels & {'needs-dev', 'needs-rework', 'changes-requested'}:
            removes.add('needs-review')

    if 'ready-for-qa' in labels:
        for l in ('needs-review', 'needs-dev'):
            if l in labels:
                removes.add(l)

    # Don't add and remove the same label in the same pass.
    removes -= adds
    emit('pr', num, adds, removes)

for it in issues:
    num = it.get('number')
    if num is None:
        continue
    labels = names(it)
    adds, removes = set(), set()

    if 'blocked' in labels:
        for l in ISSUE_TRIGGERS_BLOCKED:
            if l in labels:
                removes.add(l)
        emit('issue', num, adds, removes)
        continue

    if 'needs-dev' in labels:
        for l in ('needs-po', 'in-po', 'po-review', 'plan'):
            if l in labels:
                removes.add(l)
    if 'needs-po' in labels:
        for l in ('needs-dev', 'in-progress', 'dev'):
            if l in labels:
                removes.add(l)

    emit('issue', num, adds, removes)
PY
    )

    if [ -z "$plan" ]; then
        log "[$repo] label-state: no convergence actions needed"
        return 0
    fi

    local kind num adds removes
    while IFS=$'\t' read -r kind num adds removes; do
        [ -z "$num" ] && continue
        [ "$adds" = "-" ] && adds=""
        [ "$removes" = "-" ] && removes=""
        if $DRY_RUN; then
            log "[$repo] DRY label-converge $kind#$num adds=[${adds}] removes=[${removes}]"
            continue
        fi
        log "[$repo] label-converge $kind#$num adds=[${adds}] removes=[${removes}]"
        local label
        local IFS_ORIG="$IFS"
        IFS=','
        for label in $adds; do
            [ -z "$label" ] && continue
            backend_add_label "$repo" "$num" "$label" >/dev/null 2>&1 || true
        done
        for label in $removes; do
            [ -z "$label" ] && continue
            backend_remove_label "$repo" "$num" "$label" >/dev/null 2>&1 || true
        done
        IFS="$IFS_ORIG"
        _loop_emit_event "label_state_converged" \
            "{\"repo\":\"$repo\",\"slug\":\"$slug\",\"kind\":\"$kind\",\"number\":$num,\"added\":\"$adds\",\"removed\":\"$removes\"}" \
            || true
    done <<< "$plan"

    return 0
}

# --- Sweep: auto-close trackers / epics whose children are all done -------
# Tracker / epic issues collect a list of child issue references in their
# body. Once every child is closed, the umbrella issue is effectively done
# but humans rarely remember to close it. This sweep parses child issue
# references from the body, verifies each child's state via gh, and closes
# the tracker only when ALL referenced children are CLOSED.
#
# Parsing is intentionally narrow — false negatives (a child reference we
# don't recognise) are fine; false positives (closing a tracker with still-
# open work) are not. Recognized patterns (case-insensitive for keywords):
#   - GitHub task list checkboxes:       "- [ ] #123" / "- [x] #123"
#   - Plain "#N" inside list items:      "- See #45 for context"
#   - Keyword references:                "Tracks #N", "Sub-issue #N",
#                                        "Child: #N", "Closes #N"
# The checkbox '[x]' is treated as a hint only — the child's real state on
# the tracker is determined by `gh issue view`.
#
# Skipped:
#   - Trackers with no parseable children (we never close without proof).
#   - LOOP_AUTO_CLOSE_TRACKERS=false   (opt-out env)
# DRY_RUN honored.
reconcile_tracker_issues() {
    local repo="$1" slug="$2"

    if [ "${LOOP_AUTO_CLOSE_TRACKERS:-true}" = "false" ]; then
        return 0
    fi

    log "[$repo] tracker-close sweep"

    local trackers_json
    trackers_json=$(gh issue list --repo "$repo" --state open --limit 200 \
        --label tracker --json number,title,body,labels 2>/dev/null || echo "[]")
    local epics_json
    epics_json=$(gh issue list --repo "$repo" --state open --limit 200 \
        --label epic --json number,title,body,labels 2>/dev/null || echo "[]")

    local merged
    merged=$(TRACKERS="$trackers_json" EPICS="$epics_json" python3 - <<'PY'
import json, os
seen = {}
for raw in (os.environ.get('TRACKERS') or '[]', os.environ.get('EPICS') or '[]'):
    try:
        items = json.loads(raw)
    except Exception:
        items = []
    for it in items:
        num = it.get('number')
        if num is None or num in seen:
            continue
        seen[num] = it
print(json.dumps(list(seen.values())))
PY
    )

    local parsed
    parsed=$(TRACKERS="$merged" python3 - <<'PY'
import json, os, re
trackers = json.loads(os.environ.get('TRACKERS') or '[]')

KEYWORD_RE = re.compile(
    r'\b(?:tracks|sub-issue|child|closes?|closed|fix(?:es|ed)?|resolves?|resolved)\b[:\s]*#(\d+)',
    re.IGNORECASE,
)
CHECKBOX_RE = re.compile(r'^\s*-\s*\[[ xX]\]\s*#(\d+)')
LIST_HASH_RE = re.compile(r'^\s*[-*]\s+.*?#(\d+)')

for tr in trackers:
    num = tr.get('number')
    body = tr.get('body') or ''
    title = (tr.get('title') or '').replace('\n', ' ').strip()[:80]
    children = []
    seen = set()

    def add(n):
        try:
            n = int(n)
        except (TypeError, ValueError):
            return
        if n == num or n in seen:
            return
        seen.add(n)
        children.append(n)

    for line in body.splitlines():
        m = CHECKBOX_RE.match(line)
        if m:
            add(m.group(1))
            continue
        m = LIST_HASH_RE.match(line)
        if m:
            add(m.group(1))
        for km in KEYWORD_RE.finditer(line):
            add(km.group(1))

    if not children:
        continue
    print('\t'.join([str(num), title, ','.join(str(c) for c in children)]))
PY
    )

    if [ -z "$parsed" ]; then
        log "[$repo] tracker-close: no trackers with parseable children"
        return 0
    fi

    local tnum ttitle tchildren
    while IFS=$'\t' read -r tnum ttitle tchildren; do
        [ -z "$tnum" ] && continue
        [ -z "$tchildren" ] && continue

        local all_closed=true
        local closed_list=""
        local IFS_ORIG="$IFS"
        IFS=','
        local c
        for c in $tchildren; do
            [ -z "$c" ] && continue
            local cstate
            cstate=$(gh issue view "$c" --repo "$repo" --json state --jq .state 2>/dev/null || echo "")
            if [ "$cstate" != "CLOSED" ] && [ "$cstate" != "closed" ]; then
                all_closed=false
                break
            fi
            closed_list="${closed_list}#${c} "
        done
        IFS="$IFS_ORIG"

        if ! $all_closed; then
            log "[$repo] tracker #$tnum: open child remaining — skip"
            continue
        fi

        local comment
        comment="Loop reconciler: closing tracker — all referenced children are closed: ${closed_list%% }"

        if $DRY_RUN; then
            log "[$repo] DRY tracker-close #$tnum ($ttitle) children=${tchildren}"
            continue
        fi

        log "[$repo] tracker-close #$tnum ($ttitle) children=${tchildren}"
        backend_comment_issue "$repo" "$tnum" "$comment" \
            || log "[$repo] failed to comment on tracker #$tnum"
        backend_close_issue "$repo" "$tnum" \
            || log "[$repo] failed to close tracker #$tnum"
        _loop_emit_event "tracker_closed" \
            "{\"repo\":\"$repo\",\"slug\":\"$slug\",\"issue_num\":$tnum,\"children\":\"$tchildren\"}" \
            || true
    done <<< "$parsed"

    return 0
}

# --- Check: stuck in-review PRs — strip and re-queue after configurable timeout
# Any PR that has carried `in-review` for longer than STUCK_IN_REVIEW_MINUTES
# (default 60) with no terminal decision label is assumed to have a dead handler
# (crash, SIGKILL, reboot). Strip in-review and re-add needs-review so the
# scanner picks it up on the next tick.
STUCK_IN_REVIEW_MINUTES="${STUCK_IN_REVIEW_MINUTES:-60}"

reconcile_stuck_in_review() {
    local repo="$1"
    log "[$repo] scanning for PRs stuck in-review (>${STUCK_IN_REVIEW_MINUTES}min)"

    local prs_json
    prs_json=$(backend_list_open_prs_raw "$repo") || prs_json="[]"

    # Find PRs with in-review label. For each, get the label's applied timestamp
    # via the PR timeline items, falling back to updatedAt when unavailable.
    local stuck
    stuck=$(PJSON="$prs_json" CUTOFF_MIN="$STUCK_IN_REVIEW_MINUTES" python3 - <<'PY'
import json, os, datetime as dt

prs = json.loads(os.environ['PJSON'])
cutoff_min = float(os.environ['CUTOFF_MIN'])
now = dt.datetime.now(dt.timezone.utc)

TERMINAL = {"needs-qa", "ready-for-qa", "needs-rework", "needs-dev",
            "changes-requested", "blocked", "done"}

for pr in prs:
    labels = {l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])}
    if 'in-review' not in labels:
        continue
    # Already has a terminal decision label — the trap hasn't fired yet or
    # cleanup is in progress; don't interfere.
    if labels & TERMINAL:
        continue
    # Use updatedAt as age proxy (conservative — may underestimate how long
    # in-review has been set, but avoids false positives from timeline absence).
    up = pr.get('updatedAt', '')
    if not up:
        continue
    try:
        ts = dt.datetime.fromisoformat(up.replace('Z', '+00:00'))
    except (ValueError, TypeError):
        continue
    age_min = (now - ts).total_seconds() / 60
    if age_min >= cutoff_min:
        print(f"{pr['number']}\t{int(age_min)}\t{pr.get('title','')[:60]}")
PY
)

    if [ -z "$stuck" ]; then
        log "[$repo] no stuck in-review PRs"
        return 0
    fi

    while IFS=$'\t' read -r pr_num age title; do
        [ -z "$pr_num" ] && continue
        log "[$repo] STUCK-IN-REVIEW PR#$pr_num (${age}min): $title"
        loop_notify "Loop reconciler: $repo — PR#$pr_num stuck in-review ${age}min; stripping → needs-review"
        $DRY_RUN && continue
        backend_remove_label "$repo" "$pr_num" in-review \
            || log "[$repo] WARN: failed to remove in-review from PR#$pr_num"
        backend_add_label "$repo" "$pr_num" needs-review \
            || log "[$repo] WARN: failed to add needs-review to PR#$pr_num"
        backend_comment_pr "$repo" "$pr_num" \
            "Reconciler: PR was stuck in \`in-review\` for ${age} min with no outcome — stripping \`in-review\` and re-adding \`needs-review\` so the pipeline retries." \
            2>/dev/null || true
    done <<< "$stuck"
}

# --- Check: loop:stage:* label reconciliation --------------------------------
# Ensures every open issue carries exactly one loop:stage:<name> label that
# reflects the highest-priority trigger label currently set on the ticket.
#
# Three repair cases:
#   (a) No stage label → derive from trigger labels and add it.
#   (b) Stage label present but wrong trigger labels → reapply correct trigger,
#       remove contradicting trigger labels (stage label is the source of truth).
#   (c) Multiple stage labels → keep the one matching the highest-priority
#       trigger label and remove the rest.
#
# If no trigger labels are present on an open issue, the function leaves the
# ticket alone (no stage label is invented).  The reconciler's existing
# anomaly / lost-issue paths surface those.
#
# DRY_RUN is honoured.  Uses add-then-remove ordering (#198) for atomicity.
reconcile_stage_labels() {
    local repo="$1" slug="$2"
    log "[$repo] stage-label sync"

    # Ensure canonical state labels AND stage labels both exist before any
    # downstream handler tries to add or remove them. Without this, handlers
    # hit "'<label>' not found" from gh and abort under set -e mid-run
    # (root cause of svv2014/loop-monitor#223 stuck state on 2026-05-13).
    loop_ensure_canonical_labels_exist "$repo"
    loop_ensure_stage_labels_exist "$repo"


    local issues_json
    issues_json=$(gh issue list --repo "$repo" --state open --limit 200 \
        --json number,labels 2>/dev/null || echo "[]")

    local plan
    plan=$(ISSUES="$issues_json" SLUG="$slug" python3 - <<'PY'
import json, os

issues  = json.loads(os.environ.get('ISSUES') or '[]')
STAGE_PREFIX = 'loop:stage:'

for it in issues:
    num    = it.get('number')
    labels = {
        (l.get('name') if isinstance(l, dict) else l)
        for l in (it.get('labels') or [])
    }
    stage_labels = {l for l in labels if l.startswith(STAGE_PREFIX)}
    trigger_labels = labels - stage_labels

    # Represent trigger labels as comma-separated for shell
    trig_csv = ','.join(sorted(trigger_labels))
    stage_csv = ','.join(sorted(stage_labels))

    # Emit: number TAB trigger_csv TAB stage_csv
    print(f"{num}\t{trig_csv}\t{stage_csv}")
PY
)

    [ -z "$plan" ] && return 0

    while IFS=$'\t' read -r num trig_csv stage_csv; do
        [ -z "$num" ] && continue

        # Derive the correct stage from the current trigger labels.
        local correct_stage
        correct_stage=$(loop_stage_for_labels "$slug" "$trig_csv")

        # Parse existing stage labels into an array-like string.
        local existing_stage_label=""
        local extra_stage_labels=""
        if [ -n "$stage_csv" ]; then
            # Find first stage label and any extras.
            local first=true
            local s
            local IFS_SAVE="$IFS"
            IFS=','
            for s in $stage_csv; do
                [ -z "$s" ] && continue
                if $first; then
                    existing_stage_label="$s"
                    first=false
                else
                    extra_stage_labels="${extra_stage_labels} ${s}"
                fi
            done
            IFS="$IFS_SAVE"
        fi

        # No stage label and no triggers → nothing to invent; skip.
        if [ -z "$correct_stage" ] && [ -z "$stage_csv" ]; then
            continue
        fi

        # Stage label wins when present.  Determine the authoritative stage:
        #   - If a stage label exists, it is the authority.
        #   - Otherwise, derive from trigger labels (correct_stage).
        local auth_stage
        if [ -n "$existing_stage_label" ]; then
            auth_stage="${existing_stage_label#loop:stage:}"
        else
            auth_stage="$correct_stage"
        fi
        local auth_label="loop:stage:${auth_stage}"
        local auth_trigger
        auth_trigger=$(loop_trigger_label_for_stage "$slug" "$auth_stage" 2>/dev/null || echo "")

        # Remove extra stage labels first (keep auth_label).
        if [ -n "$extra_stage_labels" ]; then
            local s
            for s in $extra_stage_labels; do
                [ -z "$s" ] && continue
                log "[$repo] issue #$num: remove extra stage label $s"
                $DRY_RUN && continue
                backend_remove_label "$repo" "$num" "$s" >/dev/null 2>&1 || true
            done
        fi

        # Case (a): no stage label → add the derived one.
        if [ -z "$stage_csv" ]; then
            log "[$repo] issue #$num: add missing $auth_label"
            $DRY_RUN && continue
            backend_add_label "$repo" "$num" "$auth_label" >/dev/null 2>&1 || true
            continue
        fi

        # Cases (b) and (c): stage label present.
        # Ensure the correct trigger label for the authoritative stage is present.
        # Remove contradicting trigger labels (workflow triggers that don't match).
        local needs_trigger_fix=false
        if [ -n "$auth_trigger" ]; then
            case ",$trig_csv," in
                *",${auth_trigger},"*) : ;;  # already present
                *) needs_trigger_fix=true ;;
            esac
        fi

        # Also check for contradicting workflow trigger labels.
        local has_stray_triggers=false
        if [ -n "$trig_csv" ]; then
            local t
            local IFS_SAVE="$IFS"
            IFS=','
            for t in $trig_csv; do
                [ -z "$t" ] && continue
                [ "$t" = "$auth_trigger" ] && continue
                if loop_label_is_trigger "$slug" issue "$t" || loop_label_is_trigger "$slug" pr "$t"; then
                    has_stray_triggers=true
                    break
                fi
            done
            IFS="$IFS_SAVE"
        fi

        if ! $needs_trigger_fix && ! $has_stray_triggers; then
            continue  # All consistent — nothing to do.
        fi

        log "[$repo] issue #$num: stage=$auth_stage trigger_fix=$needs_trigger_fix stray=$has_stray_triggers (triggers: $trig_csv)"
        $DRY_RUN && continue

        # Add-before-remove (#198): add correct trigger first.
        if $needs_trigger_fix && [ -n "$auth_trigger" ]; then
            backend_add_label "$repo" "$num" "$auth_trigger" >/dev/null 2>&1 || true
        fi
        # Remove stray trigger labels.
        if $has_stray_triggers; then
            local t
            local IFS_SAVE="$IFS"
            IFS=','
            for t in $trig_csv; do
                [ -z "$t" ] && continue
                [ "$t" = "$auth_trigger" ] && continue
                if loop_label_is_trigger "$slug" issue "$t" || loop_label_is_trigger "$slug" pr "$t"; then
                    backend_remove_label "$repo" "$num" "$t" >/dev/null 2>&1 || true
                fi
            done
            IFS="$IFS_SAVE"
        fi

    done <<< "$plan"
}

run_project() {
    local slug="$1"
    loop_load_project "$slug" || { log "skip $slug (config error)"; return 0; }
    loop_load_backend
    if project_locked "$slug"; then
        log "=== $slug: handler active — skip reconciliation this tick"
        return 0
    fi
    log "=== $slug ($REPO) ==="
    reconcile_labels "$REPO"
    reconcile_synonym_labels "$REPO" "$slug"
    reconcile_alias_renames "$REPO" "$slug"
    reconcile_lost_issues "$REPO"
    reconcile_duplicate_prs "$REPO"
    reconcile_obsolete_open_prs "$REPO"
    reconcile_orphaned_claims "$REPO"
    reconcile_stale_prs "$REPO"
    reconcile_stuck_in_review "$REPO"
    reconcile_needs_clarification "$REPO"
    reconcile_unblock "$REPO"
    reconcile_orphaned_in_progress "$REPO" "$slug"
    reconcile_ci_red_prs "$REPO"
    reconcile_ci_green_prs "$REPO" "$slug"
    reconcile_pr_base_moved "$REPO" "$slug"
    reconcile_orphan_issues "$REPO" "$slug"
    reconcile_tracker_issues "$REPO" "$slug"
    reconcile_label_consistency "$REPO" "$slug"
    reconcile_dirty_rework_prs "$REPO"
    reconcile_conflict_blocked_prs "$REPO"
    reconcile_stale_base "$REPO"
    reconcile_stale_blocked_issues "$REPO"
    reconcile_qa_failures "$REPO"
    reconcile_qa_rework_label_drift "$REPO"
    reconcile_pr_label_audit "$REPO"
    reconcile_anomalies "$REPO"
    reconcile_agent_distress "$REPO"
    reconcile_author_gated "$slug" "$REPO"
    reconcile_closed_issue_labels "$REPO"
    reconcile_stage_labels "$REPO" "$slug"
    recovery_check_dependencies "$slug"
    reconcile_worktrees "$slug" "$REPO"
    recovery_check_stuck_labels "$slug"
    recovery_prune_orphan_worktrees
}

# Test hook: when LOOP_RECONCILER_LIB_ONLY=1, return after defining functions
# so bats files can source this script without triggering the main run.
if [ "${LOOP_RECONCILER_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

acquire_lock

# Auto-pull: always run on the latest loop code before doing any work.
# Uses --ff-only so it never merges or creates a dirty worktree — if the
# pull can't fast-forward (e.g. local diverged), skip silently and continue
# on the current checkout rather than aborting the reconcile run.
_autopull_loop() {
    local branch
    branch=$(git -C "$LOOP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ "$branch" = "main" ] || return 0
    local before after
    before=$(git -C "$LOOP_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    git -C "$LOOP_ROOT" pull --ff-only origin main --quiet 2>/dev/null || return 0
    after=$(git -C "$LOOP_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    if [ "$before" != "$after" ]; then
        log "auto-pull: updated $before → $after"
    fi
    return 0
}
$DRY_RUN || _autopull_loop

log "=== reconciler start (dry_run=$DRY_RUN only_slug=${ONLY_SLUG:-<all>}) ==="

if [ -n "$ONLY_SLUG" ]; then
    run_project "$ONLY_SLUG"
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        run_project "$slug"
    done < <(loop_list_slugs)
fi

orphans_gc=$(recovery_gc_stale_worktrees)

log "=== reconciler done orphans_gc=${orphans_gc} security_misconfig=$(security_misconfig_total) ==="
