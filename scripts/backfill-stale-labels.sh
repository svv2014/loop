#!/usr/bin/env bash
# backfill-stale-labels.sh — one-shot cleanup of stale pipeline-stage labels.
#
# Walks merged PRs and closed issues from the last N days (default 30) and
# strips every loop pipeline-stage label that should not survive a terminal
# state. Idempotent: a second non-dry-run pass makes zero changes.
#
# Defaults to --dry-run. Pass --apply to actually mutate labels.
#
# Usage:
#   scripts/backfill-stale-labels.sh                       # dry-run, all projects
#   scripts/backfill-stale-labels.sh --slug loop --apply   # apply, one project
#   scripts/backfill-stale-labels.sh --days 90 --apply     # 90-day window
#
# Touches no files outside the GitHub label state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"
# shellcheck source=../lib/labels.sh
source "$LOOP_ROOT/lib/labels.sh"

DRY_RUN=true
ONLY_SLUG=""
DAYS="${LOOP_BACKFILL_DAYS:-30}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --apply)   DRY_RUN=false; shift ;;
        --slug)    ONLY_SLUG="$2"; shift 2 ;;
        --days)    DAYS="$2"; shift 2 ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() { printf '[%s] [backfill] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

since=$(python3 -c "import datetime as d; print((d.datetime.utcnow()-d.timedelta(days=int('${DAYS}'))).strftime('%Y-%m-%d'))")
stage_csv=$(loop_pipeline_stage_labels_csv)

run_one() {
    local slug="$1"
    loop_load_project "$slug" || { log "skip $slug (config error)"; return 0; }
    loop_load_backend
    log "=== $slug ($REPO) since=${since} dry_run=$DRY_RUN ==="

    local total_changes=0

    # ---- Closed issues -----------------------------------------------------
    local issues_json
    issues_json=$(gh issue list --repo "$REPO" --state closed \
        --search "closed:>=${since}" \
        --limit 500 --json number,title,labels 2>/dev/null || echo "[]")

    local issue_targets
    issue_targets=$(ISS="$issues_json" STAGE="$stage_csv" python3 - <<'PY'
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

    local num bad title
    if [ -n "$issue_targets" ]; then
        while IFS=$'\t' read -r num bad title; do
            [ -z "$num" ] && continue
            log "[$REPO] issue #$num strip: $bad — $title"
            total_changes=$((total_changes + 1))
            $DRY_RUN && continue
            loop_strip_pipeline_labels "$REPO" "$num" "$bad" >/dev/null || true
        done <<< "$issue_targets"
    fi

    # ---- Merged PRs --------------------------------------------------------
    local prs_json
    prs_json=$(gh pr list --repo "$REPO" --state merged \
        --search "merged:>=${since}" \
        --limit 500 --json number,title,labels 2>/dev/null || echo "[]")

    local pr_targets
    pr_targets=$(PRS="$prs_json" STAGE="$stage_csv" python3 - <<'PY'
import json, os
prs = json.loads(os.environ['PRS'])
stage = set(os.environ['STAGE'].split(','))
for pr in prs:
    labels = {l['name'] for l in pr.get('labels', [])}
    bad = labels & stage
    if bad:
        print(f"{pr['number']}\t{','.join(sorted(bad))}\t{pr['title'][:60]}")
PY
)

    if [ -n "$pr_targets" ]; then
        while IFS=$'\t' read -r num bad title; do
            [ -z "$num" ] && continue
            log "[$REPO] PR #$num strip: $bad — $title"
            total_changes=$((total_changes + 1))
            $DRY_RUN && continue
            loop_strip_pipeline_labels "$REPO" "$num" "$bad" >/dev/null || true
        done <<< "$pr_targets"
    fi

    log "[$REPO] $total_changes target(s) $($DRY_RUN && echo "(dry-run, no changes applied)" || echo "applied")"
}

if [ -n "$ONLY_SLUG" ]; then
    run_one "$ONLY_SLUG"
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        run_one "$slug"
    done < <(loop_list_slugs)
fi
