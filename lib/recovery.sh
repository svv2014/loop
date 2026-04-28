#!/usr/bin/env bash
# lib/recovery.sh — recovery helpers for the Loop reconciler.
#
# Sourced by scanner/reconciler.sh. Requires REPO, DRY_RUN, log(), and
# loop_notify() to be available in the caller's environment, along with
# the backend functions loaded by loop_load_backend.
#
# Exports:
#   recovery_check_dependencies <slug>   — unblock when declared deps are merged
#   recovery_check_stuck_labels <slug>   — strip timed-out operational labels
#   recovery_prune_orphan_worktrees      — remove worktrees with no handler + no PR

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

# Default timeout (seconds). Overridable in loop.env.
HANDLER_TIMEOUT="${HANDLER_TIMEOUT:-3600}"

# Operational label → canonical upstream trigger mapping.
# Used to restore the pipeline trigger after a stuck-label strip.
#
# Note: "in-review" is aspirational — the review-handler does not yet write it
# in the default workflow. The entry is included here so the recovery logic is
# ready when a future handler begins using it, and is harmless if no issue ever
# carries that label.
_RECOVERY_OP_TO_TRIGGER=(
    "in-progress:dev"
    "in-rework:needs-rework"
    "in-review:needs-review"
)

# _recovery_trigger_for_op <operational_label>
# Echoes the canonical upstream trigger label for a given operational label,
# or an empty string if not recognised.
_recovery_trigger_for_op() {
    local op="$1"
    local entry
    for entry in "${_RECOVERY_OP_TO_TRIGGER[@]}"; do
        if [ "${entry%%:*}" = "$op" ]; then
            echo "${entry#*:}"
            return 0
        fi
    done
}

# recovery_check_stuck_labels <slug>
#
# For each open issue or PR carrying an operational label (in-progress,
# in-rework, in-review) that:
#   - has not been updated within HANDLER_TIMEOUT * 1.5 seconds, AND
#   - has no live handler process (checked via per-issue lock files)
#
# strips the operational label and restores the upstream trigger so the
# pipeline can retry. Uses loop_label_for to respect per-project overrides.
#
# DRY_RUN and log() must be available in the caller's scope.
recovery_check_stuck_labels() {
    local slug="$1"
    local repo
    repo="${REPO:-}"
    if [ -z "$repo" ]; then
        log "[recovery] ERROR: REPO not set for slug=$slug"
        return 1
    fi

    local timeout_secs
    timeout_secs=$(python3 -c "import math; print(int(math.ceil(${HANDLER_TIMEOUT} * 1.5)))")
    log "[$repo] recovery: checking stuck operational labels (timeout=${timeout_secs}s)"

    local lock_dir="${LOOP_LOCK_DIR:-/tmp/loop-locks}"
    local op_entry trigger_canon op_label issues_json candidates

    for op_entry in "${_RECOVERY_OP_TO_TRIGGER[@]}"; do
        op_label="${op_entry%%:*}"
        trigger_canon="${op_entry#*:}"

        # Resolve the project-specific label name for both labels
        local actual_op actual_trigger
        actual_op=$(loop_label_for "$slug" "$op_label" 2>/dev/null || echo "$op_label")
        actual_trigger=$(loop_label_for "$slug" "$trigger_canon" 2>/dev/null || echo "$trigger_canon")

        # Fetch issues with this operational label
        issues_json=$(backend_list_open_issues_raw "$repo" "$actual_op" 2>/dev/null || echo "[]")

        # Filter to those exceeding the timeout
        candidates=$(ISS="$issues_json" CUTOFF_S="$timeout_secs" python3 - <<'PY'
import json, os, datetime as dt
issues = json.loads(os.environ['ISS'])
cutoff_s = int(os.environ['CUTOFF_S'])
now = dt.datetime.now(dt.timezone.utc)
for iss in issues:
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z', '+00:00'))
    age_s = int((now - up).total_seconds())
    if age_s >= cutoff_s:
        print(f"{iss['number']}\t{age_s}\t{iss['title'][:60]}")
PY
)

        [ -z "$candidates" ] && continue

        while IFS=$'\t' read -r num age_s title; do
            [ -z "$num" ] && continue

            # Check for a live handler process via per-issue lock files.
            local handler_alive=false lf pid
            for lf in \
                "$lock_dir/${slug}-issue-${num}.lock" \
                "$lock_dir/po-${slug}-${num}.lock" \
                "$lock_dir/${slug}-rework-${num}.lock"; do
                [ -f "$lf" ] || continue
                pid=$(cat "$lf" 2>/dev/null || echo "")
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    handler_alive=true; break
                fi
            done

            if $handler_alive; then
                log "[$repo] recovery: issue #$num has live handler — skip ($op_label)"
                continue
            fi

            log "[$repo] recovery: STUCK $op_label on issue #$num (${age_s}s, no handler): $title → $actual_trigger"
            loop_notify "Loop recovery: $repo — issue #$num stuck in $op_label for ${age_s}s with no handler; restoring $actual_trigger"

            if ${DRY_RUN:-false}; then
                continue
            fi

            backend_remove_label "$repo" "$num" "$actual_op" \
                || log "[$repo] recovery: WARN failed to remove $actual_op from #$num"
            backend_add_label "$repo" "$num" "$actual_trigger" \
                || log "[$repo] recovery: WARN failed to add $actual_trigger to #$num"
        done <<< "$candidates"
    done
}

# recovery_prune_orphan_worktrees
#
# Scans /tmp/loop-worktree-* directories. For each:
#   - Skips dirs modified within the last 10 minutes (handler may be mid-flight)
#   - Checks if a handler lock file with a live PID covers this dir
#   - Uses backend_find_pr_for_issue to check if an open PR exists for the issue
#     number embedded in the dirname (works across github/gitlab/jira-gitlab)
#   - Removes the directory (git worktree remove --force then rm -rf fallback)
#     if neither condition is true
#
# ROOT and REPO must be set. DRY_RUN and log() must be available.
recovery_prune_orphan_worktrees() {
    local repo="${REPO:-}"
    local root="${ROOT:-}"

    log "[recovery] pruning orphan worktrees under /tmp/loop-worktree-*"

    local now_sec
    now_sec=$(date +%s)
    local grace=600  # 10-minute grace window

    local lock_dir="${LOOP_LOCK_DIR:-/tmp/loop-locks}"
    local wt_dir base num mtime age

    for wt_dir in /tmp/loop-worktree-*/; do
        [ -d "$wt_dir" ] || continue
        wt_dir="${wt_dir%/}"
        base=$(basename "$wt_dir")

        # Extract trailing numeric token as issue/PR number
        num=$(echo "$base" | grep -oE '[0-9]+$' || true)
        if [ -z "$num" ]; then
            log "[recovery] SKIP $wt_dir — cannot extract issue number"
            continue
        fi

        # Recent-activity grace window
        mtime=$(python3 -c "import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))" "$wt_dir" 2>/dev/null || echo 0)
        age=$(( now_sec - mtime ))
        if [ "$age" -lt "$grace" ]; then
            log "[recovery] SKIP $wt_dir — recently modified (${age}s < ${grace}s)"
            continue
        fi

        # Check for a live handler lock referencing this worktree/issue
        local handler_alive=false lf pid
        for lf in "$lock_dir"/*"-${num}.lock" "$lock_dir"/*"-${num}-"*.lock; do
            [ -f "$lf" ] || continue
            pid=$(cat "$lf" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                handler_alive=true; break
            fi
        done

        if $handler_alive; then
            log "[recovery] SKIP $wt_dir — live handler found"
            continue
        fi

        # Check for an open PR closing this issue using the backend abstraction
        # (supports github, gitlab, and jira-gitlab deployments).
        local open_pr=""
        if [ -n "$repo" ]; then
            open_pr=$(backend_find_pr_for_issue "$repo" "$num" 2>/dev/null || true)
        fi

        if [ -n "${open_pr:-}" ]; then
            log "[recovery] SKIP $wt_dir — open PR #$open_pr exists for issue #$num"
            continue
        fi

        log "[recovery] ORPHAN worktree $wt_dir (issue #$num, no handler, no open PR)"
        loop_notify "Loop recovery: removing orphaned worktree $wt_dir (issue #$num, no handler, no open PR)"

        if ${DRY_RUN:-false}; then
            continue
        fi

        if [ -n "$root" ]; then
            git -C "$root" worktree remove "$wt_dir" --force 2>/dev/null \
                || rm -rf "$wt_dir"
        else
            rm -rf "$wt_dir"
        fi
    done
}
