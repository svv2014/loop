#!/usr/bin/env bash
# lib/recovery.sh — recovery helpers for the Loop reconciler.
#
# Sourced by scanner/reconciler.sh. Requires REPO, DRY_RUN, log(), and
# loop_notify() to be available in the caller's environment, along with
# the backend functions loaded by loop_load_backend.

set -euo pipefail

# recovery_check_dependencies <slug>
#
# For each open issue and PR carrying the `blocked` label whose body contains
# a `## Dependencies` section: if every #N reference in that section is CLOSED
# or MERGED, remove `blocked`, restore the upstream trigger label, and post a
# human-readable comment. Items with no `## Dependencies` heading are skipped
# silently. Items with one or more open deps are left unchanged with a single
# log line.
#
# Restore label: `loop_label_for <slug> dev` for issues (fallback: "dev");
# always `needs-review` for PRs.
recovery_check_dependencies() {
    local slug="$1"
    local repo="${REPO:-}"
    [ -z "$repo" ] && { log "[recovery] ERROR: REPO not set"; return 1; }

    log "[$repo] recovery_check_dependencies: scanning blocked issues and PRs"

    # ---- Blocked issues -------------------------------------------------------
    local blocked_json
    blocked_json=$(backend_list_open_issues_raw "$repo" "blocked")

    local candidates
    candidates=$(ITEMS="$blocked_json" python3 - <<'PY'
import json, os, re
items = json.loads(os.environ['ITEMS'])
NUM = re.compile(r'#(\d+)')
for item in items:
    body = item.get('body') or ''
    lines = body.splitlines()
    in_dep = False
    dep_lines = []
    for line in lines:
        if re.match(r'^##\s+Dependencies\s*$', line, re.I):
            in_dep = True
            continue
        if in_dep and re.match(r'^##', line):
            break
        if in_dep:
            dep_lines.append(line)
    if not in_dep:
        continue
    deps = sorted(set(int(n) for n in NUM.findall('\n'.join(dep_lines))))
    deps = [n for n in deps if n != item['number']]
    if not deps:
        continue
    print(f"{item['number']}\t{','.join(str(n) for n in deps)}\t{item['title'][:60]}")
PY
)

    local num deps trigger_label dep_list
    local all_closed unresolved dep dep_arr st
    while IFS=$'\t' read -r num deps _title; do
        [ -z "$num" ] && continue
        all_closed=true
        unresolved=""
        IFS=',' read -ra dep_arr <<< "$deps"
        for dep in "${dep_arr[@]}"; do
            st=$(gh issue view "$dep" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
            if [ "$st" != "CLOSED" ]; then
                st=$(gh pr view "$dep" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
            fi
            if [ "$st" = "CLOSED" ] || [ "$st" = "MERGED" ]; then
                : # dep satisfied
            else
                all_closed=false
                unresolved="${unresolved}#${dep} (${st}) "
            fi
        done

        if $all_closed; then
            trigger_label=$(loop_label_for "$slug" "dev" 2>/dev/null) || trigger_label="dev"
            [ -z "$trigger_label" ] && trigger_label="dev"
            dep_list=$(DEP_NUMS="$deps" python3 -c "
import os; nums=os.environ['DEP_NUMS'].split(','); print(', '.join('#'+n for n in nums))")
            log "[$repo] UNBLOCK issue #$num (deps ${deps} satisfied): restoring to ${trigger_label}"
            loop_notify "Loop reconciler: $repo — unblocking issue #$num; deps (${deps}) all closed. Relabeling → ${trigger_label}." || true
            $DRY_RUN && continue
            backend_remove_label "$repo" "$num" blocked \
                || log "[$repo] WARN: failed to remove blocked from issue #$num"
            backend_add_label "$repo" "$num" "$trigger_label" \
                || log "[$repo] WARN: failed to add ${trigger_label} to issue #$num"
            backend_comment_issue "$repo" "$num" \
                "Dependency ${dep_list} is now closed/merged. Unblocking and restoring to pipeline." \
                || log "[$repo] WARN: failed to comment on issue #$num"
        else
            log "[$repo] issue #$num still blocked by: ${unresolved}"
        fi
    done <<< "$candidates"

    # ---- Blocked PRs ----------------------------------------------------------
    local all_prs_json
    all_prs_json=$(backend_list_open_prs_raw "$repo")

    local pr_candidates
    pr_candidates=$(PJSON="$all_prs_json" python3 - <<'PY'
import json, os, re
prs = json.loads(os.environ['PJSON'])
NUM = re.compile(r'#(\d+)')
for pr in prs:
    lbls = [l['name'] if isinstance(l, dict) else l for l in pr.get('labels', [])]
    if 'blocked' not in lbls:
        continue
    body = pr.get('body') or ''
    lines = body.splitlines()
    in_dep = False
    dep_lines = []
    for line in lines:
        if re.match(r'^##\s+Dependencies\s*$', line, re.I):
            in_dep = True
            continue
        if in_dep and re.match(r'^##', line):
            break
        if in_dep:
            dep_lines.append(line)
    if not in_dep:
        continue
    deps = sorted(set(int(n) for n in NUM.findall('\n'.join(dep_lines))))
    deps = [n for n in deps if n != pr['number']]
    if not deps:
        continue
    print(f"{pr['number']}\t{','.join(str(n) for n in deps)}\t{pr['title'][:60]}")
PY
)

    local pr_num
    while IFS=$'\t' read -r pr_num deps _title; do
        [ -z "$pr_num" ] && continue
        all_closed=true
        unresolved=""
        IFS=',' read -ra dep_arr <<< "$deps"
        for dep in "${dep_arr[@]}"; do
            st=$(gh issue view "$dep" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
            if [ "$st" != "CLOSED" ]; then
                st=$(gh pr view "$dep" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
            fi
            if [ "$st" = "CLOSED" ] || [ "$st" = "MERGED" ]; then
                : # dep satisfied
            else
                all_closed=false
                unresolved="${unresolved}#${dep} (${st}) "
            fi
        done

        if $all_closed; then
            dep_list=$(DEP_NUMS="$deps" python3 -c "
import os; nums=os.environ['DEP_NUMS'].split(','); print(', '.join('#'+n for n in nums))")
            log "[$repo] UNBLOCK PR #$pr_num (deps ${deps} satisfied): restoring to needs-review"
            loop_notify "Loop reconciler: $repo — unblocking PR #$pr_num; deps (${deps}) all closed. Relabeling → needs-review." || true
            $DRY_RUN && continue
            backend_remove_label "$repo" "$pr_num" blocked \
                || log "[$repo] WARN: failed to remove blocked from PR #$pr_num"
            backend_add_label "$repo" "$pr_num" needs-review \
                || log "[$repo] WARN: failed to add needs-review to PR #$pr_num"
            backend_comment_pr "$repo" "$pr_num" \
                "Dependency ${dep_list} is now closed/merged. Unblocking and restoring to pipeline." \
                || log "[$repo] WARN: failed to comment on PR #$pr_num"
        else
            log "[$repo] PR #$pr_num still blocked by: ${unresolved}"
        fi
    done <<< "$pr_candidates"
}
