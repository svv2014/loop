#!/usr/bin/env bash
# lib/recovery.sh — active-recovery helpers for scanner/reconciler.sh.
#
# Exports:
#   recovery_check_stuck_labels <slug>   — strip timed-out operational labels
#   recovery_prune_orphan_worktrees      — remove worktrees with no handler + no PR
#
# Sourced by scanner/reconciler.sh after lib/env.sh, lib/config.sh, and the
# backend adapter. All backend_* functions must already be in scope.

# Default timeout (seconds). Overridable in loop.env.
HANDLER_TIMEOUT="${HANDLER_TIMEOUT:-3600}"

# Operational label → canonical upstream trigger mapping.
# Used to restore the pipeline trigger after a stuck-label strip.
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
# Scans /tmp/loop-worktree-* directories that do NOT have the standard
# slug-specific naming (those are handled by reconcile_worktrees). For each:
#   - Skips dirs modified within the last 10 minutes (handler may be mid-flight)
#   - Checks if a handler lock file with a live PID covers this dir
#   - Checks if an open PR exists for the issue number embedded in the dirname
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

        # Check for an open PR closing this issue
        local open_pr_count
        if [ -n "$repo" ]; then
            open_pr_count=$(gh pr list --repo "$repo" --state open \
                --json number,body --jq \
                "[.[] | select(.body | test(\"(clos(e|es|ed)|fix(|es|ed)|resolv(e|es|ed))\\\\s+#${num}\"; \"i\"))] | length" \
                2>/dev/null || echo 0)
        else
            open_pr_count=0
        fi

        if [ "${open_pr_count:-0}" -gt 0 ]; then
            log "[recovery] SKIP $wt_dir — open PR exists for issue #$num"
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
