#!/usr/bin/env bash
# backfill-stage-labels.sh — apply loop:stage:* labels to all open tickets.
#
# Walks every open issue in the target project(s) and ensures each one carries
# the correct loop:stage:<name> label derived from its current trigger labels.
# Idempotent: a second pass makes no changes when labels are already correct.
#
# Defaults to --dry-run.  Pass --apply to actually mutate labels.
#
# Usage:
#   scripts/backfill-stage-labels.sh --slug loop --dry-run
#   scripts/backfill-stage-labels.sh --slug loop --apply
#   scripts/backfill-stage-labels.sh --apply          # all projects

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"
# shellcheck source=../lib/workflow.sh
source "$LOOP_ROOT/lib/workflow.sh"
# shellcheck source=../lib/stage.sh
source "$LOOP_ROOT/lib/stage.sh"

DRY_RUN=true
ONLY_SLUG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true;  shift ;;
        --apply)   DRY_RUN=false; shift ;;
        --slug)    ONLY_SLUG="$2"; shift 2 ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() { printf '[%s] [backfill-stage] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

STAGE_PREFIX="loop:stage:"

run_one() {
    local slug="$1"
    loop_load_project "$slug" || { log "skip $slug (config error)"; return 0; }
    loop_load_backend
    log "=== $slug ($REPO) dry_run=$DRY_RUN ==="

    # Ensure all loop:stage:* labels exist in the repo before applying any.
    loop_ensure_stage_labels_exist "$REPO"

    local issues_json
    issues_json=$(gh issue list --repo "$REPO" --state open --limit 500 \
        --json number,labels 2>/dev/null || echo "[]")

    local total=0 changed=0

    while IFS=$'\t' read -r num trig_csv stage_csv; do
        [ -z "$num" ] && continue
        total=$((total + 1))

        local correct_stage
        correct_stage=$(loop_stage_for_labels "$slug" "$trig_csv")

        if [ -z "$correct_stage" ]; then
            # Remove dangling stage labels when there are no trigger labels.
            if [ -n "$stage_csv" ]; then
                log "[$REPO] issue #$num: no triggers — removing dangling: $stage_csv"
                changed=$((changed + 1))
                $DRY_RUN && continue
                local s IFS_SAVE="$IFS"
                IFS=','
                for s in $stage_csv; do
                    [ -z "$s" ] && continue
                    backend_remove_label "$REPO" "$num" "$s" >/dev/null 2>&1 || true
                done
                IFS="$IFS_SAVE"
            fi
            continue
        fi

        local correct_label="${STAGE_PREFIX}${correct_stage}"

        # Check whether the correct label is already the only stage label.
        case ",$stage_csv," in
            *",${correct_label},"*)
                # Correct label present — remove any extras.
                local s IFS_SAVE="$IFS"
                IFS=','
                for s in $stage_csv; do
                    [ -z "$s" ] && continue
                    [ "$s" = "$correct_label" ] && continue
                    log "[$REPO] issue #$num: remove extra stage label $s"
                    changed=$((changed + 1))
                    $DRY_RUN && { IFS="$IFS_SAVE"; continue; }
                    backend_remove_label "$REPO" "$num" "$s" >/dev/null 2>&1 || true
                done
                IFS="$IFS_SAVE"
                continue
                ;;
        esac

        log "[$REPO] issue #$num: set $correct_label (was: '${stage_csv:-<none>}')"
        changed=$((changed + 1))
        $DRY_RUN && continue

        # Add-then-remove for atomicity (#198).
        backend_add_label "$REPO" "$num" "$correct_label" >/dev/null 2>&1 || true
        if [ -n "$stage_csv" ]; then
            local s IFS_SAVE="$IFS"
            IFS=','
            for s in $stage_csv; do
                [ -z "$s" ] && continue
                [ "$s" = "$correct_label" ] && continue
                backend_remove_label "$REPO" "$num" "$s" >/dev/null 2>&1 || true
            done
            IFS="$IFS_SAVE"
        fi

    done < <(ISSUES="$issues_json" STAGE_PREFIX="$STAGE_PREFIX" python3 - <<'PY'
import json, os

issues = json.loads(os.environ.get('ISSUES') or '[]')
prefix = os.environ['STAGE_PREFIX']

for it in issues:
    num    = it.get('number')
    labels = {
        (l.get('name') if isinstance(l, dict) else l)
        for l in (it.get('labels') or [])
    }
    stage_labels   = {l for l in labels if l.startswith(prefix)}
    trigger_labels = labels - stage_labels
    print(f"{num}\t{','.join(sorted(trigger_labels))}\t{','.join(sorted(stage_labels))}")
PY
)

    log "[$REPO] $total issue(s) scanned; $changed change(s) $($DRY_RUN && echo "(dry-run, no mutations)" || echo "applied")"
}

if [ -n "$ONLY_SLUG" ]; then
    run_one "$ONLY_SLUG"
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        run_one "$slug"
    done < <(loop_list_slugs)
fi
