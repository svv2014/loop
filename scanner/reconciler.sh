#!/usr/bin/env bash
# reconciler.sh — Loop pipeline housekeeping.
#
# Detects and (where safe) fixes drift that the event-driven pipeline doesn't
# self-correct. Runs every ~15 min via launchd (com.example.loop-reconciler).
#
# Checks (per project):
#   1. DUPLICATE_PRS — multiple OPEN PRs close the same issue (body contains
#      "Closes #N"). Keep the newest PR number, close the rest with a comment.
#   2. ORPHANED_CLAIMS — issue carries a "claimed" label (review-pending)
#      but no OPEN PR closes it. Strip the stale label so the scanner/dev
#      handler picks the issue up again.
#   3. STALE_PRS — PRs sitting >24h in review-pending/changes-requested
#      without an update. Logged + announced to Signal ops (no auto-fix).
#
# Modes:
#   reconciler.sh                 # single sweep across all projects
#   reconciler.sh --dry-run       # report findings only, no mutations
#   reconciler.sh --slug ppl      # limit to one project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-reconciler.log"
LOCK_FILE="/tmp/loop-reconciler.lock"
# Notifications via loop_notify (configured in loop.env)
STALE_PR_HOURS="${LOOP_STALE_PR_HOURS:-24}"

DRY_RUN=false
ONLY_SLUG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --slug)    ONLY_SLUG="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

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
    local map; map=$(PRS="$prs_json" python3 - <<'PY'
import json, re, os
prs = json.loads(os.environ['PRS'])
m = {}
pat = re.compile(r'(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\s+#(\d+)', re.I)
for pr in prs:
    seen = set()
    for n in pat.findall(pr.get('body') or ''):
        if n in seen: continue
        seen.add(n)
        m.setdefault(n, []).append({'pr': pr['number'], 'createdAt': pr['createdAt'], 'title': pr['title']})
for issue, plist in m.items():
    if len(plist) <= 1: continue
    plist.sort(key=lambda x: x['pr'], reverse=True)
    keep = plist[0]
    for dup in plist[1:]:
        print(f"{issue}\t{keep['pr']}\t{dup['pr']}\t{dup['title'][:60]}")
PY
)

    if [ -z "$map" ]; then
        log "[$repo] no duplicate PRs"
        return 0
    fi

    while IFS=$'\t' read -r issue keep dup title; do
        [ -z "$issue" ] && continue
        log "[$repo] DUP issue #$issue: keep PR#$keep, close PR#$dup ($title)"
        loop_notify "Loop reconciler: $repo — closing duplicate PR#$dup (issue #$issue); keeping PR#$keep"
        $DRY_RUN && continue
        backend_comment_pr "$repo" "$dup" \
            "Closed by Loop reconciler — duplicate of #$keep (both close issue #$issue)."
        backend_close_pr "$repo" "$dup" --delete-branch \
            || log "[$repo] failed to close PR#$dup"
    done <<< "$map"
}

# --- Check 2: orphaned claimed issues --------------------------------------
# "Claimed" markers on issues = review-pending (dev-handler set it when
# opening a PR). If the matching PR got closed without merging, the issue
# stays stuck under review-pending with no active PR. Reset so the pipeline
# can retry.
reconcile_orphaned_claims() {
    local repo="$1"
    log "[$repo] scanning for orphaned review-pending issues"

    local issues_json issues_new_json
    issues_json=$(backend_list_open_issues_raw "$repo" "review-pending")
    issues_new_json=$(backend_list_open_issues_raw "$repo" "needs-review")
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
    #   "merged"   — a PR already merged closing it (strip review-pending, close issue)
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
            log "[$repo] STALE-LABEL issue #$num (review-pending, PR already merged): $title"
            loop_notify "Loop reconciler: $repo — issue #$num PR merged but review-pending label stuck; stripping + closing issue"
            $DRY_RUN && continue
            backend_remove_label "$repo" "$num" review-pending \
                || log "[$repo] failed to strip label from issue #$num"
            backend_comment_issue "$repo" "$num" \
                "Closed by Loop reconciler — merged PR closing this issue didn't auto-close it."
            backend_close_issue "$repo" "$num" \
                || log "[$repo] failed to close issue #$num"
        else
            log "[$repo] ORPHAN issue #$num (review-pending, no PR): $title"
            loop_notify "Loop reconciler: $repo — issue #$num has review-pending label but no PR; resetting to dev"
            $DRY_RUN && continue
            backend_remove_label "$repo" "$num" review-pending \
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
    stale=$(PRS="$prs_json" CUTOFF_H="$STALE_PR_HOURS" python3 - <<'PY'
import json, os, datetime as dt
data = json.loads(os.environ['PRS'])
now = dt.datetime.now(dt.timezone.utc)
watched = {"review-pending","needs-review","changes-requested","needs-rework","in-review","ready-for-qa","needs-qa","qa-fail","qa-failed"}
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

        # Auto-recover: needs-review stuck >24h → relabel to review-pending so scanner picks it up
        if echo "$labels" | grep -q "needs-review" && ! echo "$labels" | grep -q "in-review"; then
            log "[$repo] AUTO-RECOVER PR#$num: needs-review → review-pending"
            backend_remove_label "$repo" "$num" needs-review || true
            backend_add_label    "$repo" "$num" review-pending || true
            loop_notify "Loop reconciler: $repo — PR#$num auto-recovered needs-review→review-pending after ${age}h"
        # Auto-recover: has both ready-for-qa + needs-rework (belt-and-braces bug) → strip needs-rework
        elif echo "$labels" | grep -q "needs-rework" && echo "$labels" | grep -q "ready-for-qa"; then
            log "[$repo] AUTO-RECOVER PR#$num: stripping spurious needs-rework (ready-for-qa already set)"
            backend_remove_label "$repo" "$num" needs-rework || true
            loop_notify "Loop reconciler: $repo — PR#$num stripped spurious needs-rework after ${age}h (ready-for-qa was set)"
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

# --- Check 8: lost issues (no pipeline label → route back to po-review) -----
# Open issues that have no Loop pipeline label at all are invisible to the
# scanner and all handlers. Detect them and send back to po-review so the PO
# agent can triage (re-spec, close, cancel, or upgrade to epic).
LOOP_PIPELINE_LABELS="po-review plan dev in-progress review-pending needs-review in-review needs-qa ready-for-qa in-rework needs-rework changes-requested needs-clarification blocked qa-fail qa-pass done tracker"

reconcile_lost_issues() {
    local repo="$1"
    log "[$repo] scanning for lost issues (no pipeline label)"

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

    while IFS=$'\t' read -r num title; do
        [ -z "$num" ] && continue
        log "[$repo] LOST issue #$num (no pipeline label): $title — routing to po-review"
        $DRY_RUN && continue
        backend_add_label "$repo" "$num" po-review \
            || log "[$repo] WARN: failed to add po-review to issue #$num"
        backend_comment_issue "$repo" "$num" \
            "Reconciler: issue had no pipeline label — routed back to \`po-review\` for triage." \
            || true
        loop_notify "Loop reconciler: $repo — issue #$num had no pipeline label; sent to po-review: $title"
    done <<< "$lost"
}

# --- Check 9: required Loop labels (bootstrap + drift correction) ----------
# Ensures every repo in the pipeline has the full set of Loop labels.
# Creates any missing labels silently. This prevents handlers from failing to
# apply labels and leaving PRs/issues with no labels (a known stuck-pipeline
# failure mode when a repo is first onboarded without bootstrapping).
LOOP_REQUIRED_LABELS=(
    "po-review:PO agent review queue:#1D76DB"
    "dev:Automated dev cycle:#0075CA"
    "in-progress:Currently being worked on:#FFA500"
    "review-pending:PR open, waiting for review:#9370DB"
    "needs-review:Ready for human review:#0075ca"
    "in-review:Review in progress:#6A5ACD"
    "needs-qa:Review approved, pending QA:#FFD700"
    "ready-for-qa:Approved, needs QA:#FFD700"
    "in-rework:Dev agent addressing reviewer feedback:#FFD700"
    "needs-rework:Review rejected, dev must rework:#DC143C"
    "changes-requested:Reviewer requested changes:#FFA07A"
    "needs-clarification:Dev hit ambiguity:#FF69B4"
    "blocked:Failed 3x, needs human:#8B0000"
    "qa-fail:QA failed, back to dev:#DC143C"
    "qa-pass:QA passed, ready to merge:#32CD32"
    "done:Merged and closed:#006400"
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
            backend_remove_label "$repo" "$issue_num" blocked qa-pass changes-requested in-rework 2>/dev/null || true
            backend_add_label "$repo" "$issue_num" dev 2>/dev/null || true
            log "[$repo] re-queued issue #$issue_num → dev"
        done

        # If no Closes link found, just log — don't close with no re-queue plan
        if [ -z "$issue_nums" ]; then
            log "[$repo] WARN: PR #$pr_num has no Closes link — closed but no issue re-queued"
        fi
    done
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
    reconcile_lost_issues "$REPO"
    reconcile_duplicate_prs "$REPO"
    reconcile_obsolete_open_prs "$REPO"
    reconcile_orphaned_claims "$REPO"
    reconcile_stale_prs "$REPO"
    reconcile_needs_clarification "$REPO"
    reconcile_unblock "$REPO"
    reconcile_orphaned_in_progress "$REPO" "$slug"
    reconcile_conflict_blocked_prs "$REPO"
    reconcile_qa_failures "$REPO"
    reconcile_worktrees "$slug" "$REPO"
}

acquire_lock
log "=== reconciler start (dry_run=$DRY_RUN only_slug=${ONLY_SLUG:-<all>}) ==="

if [ -n "$ONLY_SLUG" ]; then
    run_project "$ONLY_SLUG"
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        run_project "$slug"
    done < <(loop_list_slugs)
fi

log "=== reconciler done ==="
