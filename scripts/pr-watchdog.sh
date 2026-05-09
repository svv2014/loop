#!/usr/bin/env bash
# pr-watchdog.sh — auto-rework stale loop-authored PRs.
#
# Polls every project's open PRs and labels them `needs-rework` if they are:
#   - authored by an account in ALLOWED_AUTHORS (per-project, from projects.yaml), and
#   - sitting with a merge conflict for >CONFLICT_GRACE_SECONDS, or
#   - failing CI for >CI_GRACE_SECONDS,
#   - and don't already carry needs-rework / blocked / needs-clarification.
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

log "tick start (conflict-grace=${CONFLICT_GRACE_SECONDS}s ci-grace=${CI_GRACE_SECONDS}s dry-run=${DRY_RUN})"

# Walk every project. loop_load_project sets REPO and ALLOWED_AUTHORS.
while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    if ! loop_load_project "$slug" 2>/dev/null; then
        log "skip $slug (load failed)"
        continue
    fi
    if [ -z "${ALLOWED_AUTHORS:-}" ]; then
        log "skip $slug (ALLOWED_AUTHORS empty — gate disabled)"
        continue
    fi

    # One JSON dump per repo, piped to filter.
    local_payload=$(gh pr list --repo "$REPO" --state open --limit 50 \
        --json number,author,labels,mergeable,statusCheckRollup,createdAt,updatedAt \
        2>/dev/null || echo "[]")

    while IFS=$'\t' read -r num reason; do
        [ -z "$num" ] && continue
        if $DRY_RUN; then
            log "DRY $slug #$num would-rework: $reason"
            continue
        fi
        log "rework $slug #$num: $reason"
        if backend_add_label "$REPO" "$num" needs-rework 2>/dev/null; then
            loop_notify "🛠 [$slug] PR #$num auto-rework: $reason" || true
        else
            log "WARN: failed to add label to $slug #$num"
        fi
    done < <(printf '%s' "$local_payload" | python3 "$LOOP_ROOT/scripts/_watchdog_filter.py" \
            --conflict-grace "$CONFLICT_GRACE_SECONDS" \
            --ci-grace "$CI_GRACE_SECONDS" \
            --allowed-authors "$ALLOWED_AUTHORS")
done < <(loop_list_slugs)

log "tick done"
