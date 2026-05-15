#!/usr/bin/env bash
# pr-watchdog.sh — auto-rework stale loop-authored PRs.
#
# Polls every project's open PRs and labels them with the project's rework
# trigger label (resolved via loop_stage_trigger; falls back to needs-rework) if:
#   - authored by an account in ALLOWED_AUTHORS (per-project, from projects.yaml), and
#   - sitting with a merge conflict for >CONFLICT_GRACE_SECONDS, or
#   - failing CI for >CI_GRACE_SECONDS,
#   - and don't already carry the rework trigger / needs-rework / blocked / needs-clarification.
#
# Designed to run every ~15 min via launchd / cron. The dev-rework handler
# downstream picks up the label and rebases + fixes.
#
# Flags:
#   --dry-run   list what would be relabeled, don't touch GH
#   --once      single sweep (default; loop-mode is for future use)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/workflow.sh
source "$LOOP_ROOT/lib/workflow.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"

CONFLICT_GRACE_SECONDS="${LOOP_WATCHDOG_CONFLICT_GRACE:-900}"   # 15 min
CI_GRACE_SECONDS="${LOOP_WATCHDOG_CI_GRACE:-1800}"              # 30 min
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    : ;;  # default behavior; reserved
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pr-watchdog] $*"; }

# _try_clean_rebase <repo> <pr_num> <head_branch>
# Attempts a cheap clean rebase of the PR head onto its base branch.
# Returns 0 and pushes if rebase is clean; returns non-zero otherwise (no side effects).
_try_clean_rebase() {
    local repo="$1" pr_num="$2" head_branch="$3"
    local tmp_dir
    tmp_dir="${TMPDIR:-/tmp}/loop-rebase-$(printf '%s' "$repo" | tr '/' '-')-${pr_num}"
    rm -rf "$tmp_dir"

    if ! gh repo clone "$repo" "$tmp_dir" -- --depth=50 --quiet 2>/dev/null; then
        log "WARN: PR #${pr_num} clone failed, skipping auto-rebase"
        return 1
    fi

    local base
    base=$(gh pr view "$pr_num" --repo "$repo" --json baseRefName --jq .baseRefName 2>/dev/null) || {
        rm -rf "$tmp_dir"
        return 1
    }
    if [ -z "$base" ]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    local rebase_ok=1
    (
        cd "$tmp_dir" || exit 1
        git fetch origin "$head_branch" --quiet 2>/dev/null || exit 1
        git fetch origin "$base" --quiet 2>/dev/null || exit 1
        git checkout "$head_branch" --quiet 2>/dev/null || exit 1
        behind=$(git rev-list --count "origin/${base}...HEAD" 2>/dev/null || echo "999")
        if [ "$behind" -gt 50 ]; then
            log "pr-watchdog: PR #${pr_num} too far behind base (${behind} commits), deferring to dev-rework"
            exit 1
        fi
        if git rebase "origin/$base" 2>/dev/null; then
            git push origin "$head_branch" --force-with-lease 2>/dev/null || exit 1
            exit 0
        fi
        git rebase --abort 2>/dev/null || true
        exit 1
    ) && rebase_ok=0

    rm -rf "$tmp_dir"
    if [ "$rebase_ok" -eq 0 ]; then
        log "pr-watchdog: auto-rebased PR #${pr_num} onto ${base}"
    fi
    return "$rebase_ok"
}

log "tick start (conflict-grace=${CONFLICT_GRACE_SECONDS}s ci-grace=${CI_GRACE_SECONDS}s dry-run=${DRY_RUN})"

# Walk every project. loop_load_project sets REPO and ALLOWED_AUTHORS.
while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    if loop_project_is_paused "$slug"; then
        log "paused: skipping $slug"
        continue
    fi
    if ! loop_load_project "$slug" 2>/dev/null; then
        log "skip $slug (load failed)"
        continue
    fi
    if [ -z "${ALLOWED_AUTHORS:-}" ]; then
        log "skip $slug (ALLOWED_AUTHORS empty — gate disabled)"
        continue
    fi

    rework_label=$(loop_stage_trigger "$slug" "rework" "pr" 2>/dev/null || echo "")
    [ -z "$rework_label" ] && rework_label="needs-rework"

    # One JSON dump per repo, piped to filter.
    local_payload=$(gh pr list --repo "$REPO" --state open --limit 50 \
        --json number,author,labels,mergeable,statusCheckRollup,createdAt,updatedAt \
        2>/dev/null || echo "[]")

    while IFS=$'\t' read -r num reason; do
        [ -z "$num" ] && continue

        # For CONFLICTING PRs, try a cheap clean rebase before triggering dev-rework.
        case "$reason" in
            conflict*)
                if ! $DRY_RUN; then
                    head_branch=$(gh pr view "$num" --repo "$REPO" \
                        --json headRefName --jq .headRefName 2>/dev/null || echo "")
                    if [ -n "$head_branch" ] && _try_clean_rebase "$REPO" "$num" "$head_branch"; then
                        continue
                    fi
                fi
                ;;
        esac

        if $DRY_RUN; then
            log "DRY $slug #$num would-rework ($rework_label): $reason"
            continue
        fi
        log "rework $slug #$num ($rework_label): $reason"
        if backend_add_label "$REPO" "$num" "$rework_label" 2>/dev/null; then
            loop_notify "🛠 [$slug] PR #$num auto-rework ($rework_label): $reason" || true
        else
            log "WARN: failed to add label $rework_label to $slug #$num"
        fi
    done < <(printf '%s' "$local_payload" | python3 "$LOOP_ROOT/scripts/_watchdog_filter.py" \
            --conflict-grace "$CONFLICT_GRACE_SECONDS" \
            --ci-grace "$CI_GRACE_SECONDS" \
            --allowed-authors "$ALLOWED_AUTHORS" \
            --exclude-labels "$rework_label,blocked,needs-clarification,needs-rework")
done < <(loop_list_slugs)

log "tick done"
