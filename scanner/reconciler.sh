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
            local mtime; mtime=$(stat -f %m "$sentinel" 2>/dev/null || stat -c %Y "$sentinel" 2>/dev/null || echo 0)
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
            local mtime; mtime=$(stat -f %m "$sentinel" 2>/dev/null || stat -c %Y "$sentinel" 2>/dev/null || echo 0)
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
            local mtime; mtime=$(stat -f %m "$sentinel" 2>/dev/null || stat -c %Y "$sentinel" 2>/dev/null || echo 0)
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
    reconcile_needs_clarification "$REPO"
    reconcile_unblock "$REPO"
    reconcile_orphaned_in_progress "$REPO" "$slug"
    reconcile_dirty_rework_prs "$REPO"
    reconcile_conflict_blocked_prs "$REPO"
    reconcile_stale_base "$REPO"
    reconcile_stale_blocked_issues "$REPO"
    reconcile_qa_failures "$REPO"
    reconcile_pr_label_audit "$REPO"
    reconcile_anomalies "$REPO"
    reconcile_agent_distress "$REPO"
    reconcile_author_gated "$slug" "$REPO"
    reconcile_closed_issue_labels "$REPO"
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

log "=== reconciler done orphans_gc=${orphans_gc} ==="
