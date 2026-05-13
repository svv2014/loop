#!/usr/bin/env bash
# scripts/loop-recover.sh — operator command to roll a ticket back to its
# last known-good pipeline stage.
#
# Usage:
#   loop-recover.sh <issue-or-pr-number> [--slug <slug>] [--to-stage <stage>] [--dry-run]
#
# Stages: po | dev | review | qa | merge
#
# Without --to-stage, reads the event log (LOOP_MONITOR_LOG or
# $LOOP_LOG_DIR/loop-monitor-events.jsonl), finds the most recent *_done
# event for this ticket, and maps it to the next pipeline stage.
#
# With --to-stage, forces the ticket to the named stage's label set.
#
# --dry-run prints planned operations without mutating GitHub.
#
# See README.md "Recovery" section for full documentation.

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
# shellcheck source=../lib/stage.sh
source "$LOOP_ROOT/lib/stage.sh"

TICKET_NUM=""
SLUG=""
TO_STAGE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)
            shift; SLUG="$1"
            ;;
        --to-stage)
            shift; TO_STAGE="$1"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        -*)
            printf 'ERROR: unknown flag: %s\n' "$1" >&2; exit 2
            ;;
        *)
            if [ -z "$TICKET_NUM" ]; then
                TICKET_NUM="$1"
            else
                printf 'ERROR: unexpected argument: %s\n' "$1" >&2; exit 2
            fi
            ;;
    esac
    shift
done

[ -n "$TICKET_NUM" ] || { printf 'ERROR: ticket number required\n' >&2; exit 2; }

if [ -n "$TO_STAGE" ]; then
    case "$TO_STAGE" in
        po|dev|review|qa|merge) ;;
        *) printf 'ERROR: invalid stage %q. Valid: po dev review qa merge\n' "$TO_STAGE" >&2; exit 2 ;;
    esac
fi

log() { printf '[loop-recover] %s\n' "$*" >&2; }

# Resolve slug — use --slug, or auto-detect when only one project is configured.
if [ -z "$SLUG" ]; then
    mapfile -t _slugs < <(loop_list_slugs 2>/dev/null || true)
    if [ "${#_slugs[@]}" -eq 1 ]; then
        SLUG="${_slugs[0]}"
        log "auto-detected slug: $SLUG"
    else
        printf 'ERROR: --slug is required (found %d projects; cannot auto-detect)\n' \
            "${#_slugs[@]}" >&2
        exit 2
    fi
fi

loop_load_project "$SLUG" || { printf 'ERROR: unknown slug %q\n' "$SLUG" >&2; exit 2; }
loop_load_backend

# ---------------------------------------------------------------------------
# Determine target stage
# ---------------------------------------------------------------------------
TARGET_STAGE=""
REASON=""

if [ -n "$TO_STAGE" ]; then
    TARGET_STAGE="$TO_STAGE"
    REASON="operator-forced to stage $TO_STAGE"
else
    # Locate the event log (JSONL file written by loop-monitor or a log shipper).
    MONITOR_LOG="${LOOP_MONITOR_LOG:-${LOOP_LOG_DIR}/loop-monitor-events.jsonl}"

    if [ ! -f "$MONITOR_LOG" ]; then
        printf 'ERROR: no event log found at %s\n' "$MONITOR_LOG" >&2
        printf '  Set LOOP_MONITOR_LOG or pass --to-stage <stage> to skip auto-detection.\n' >&2
        exit 2
    fi

    # Parse the log: find the most recent *_done event for this ticket number.
    # Supports two line formats:
    #   {"type":"dev_done","payload":{"issue_num":42,...}}  (_loop_emit_event format)
    #   {"event":"dev_done","issue_num":42,...}             (flat bounty format)
    TARGET_STAGE=$(MONITOR_LOG="$MONITOR_LOG" TICKET_NUM="$TICKET_NUM" python3 - <<'PY'
import os, sys, json

log_path = os.environ['MONITOR_LOG']
ticket   = os.environ['TICKET_NUM']

DONE_TO_STAGE = {
    'po_done':     'dev',
    'dev_done':    'review',
    'review_done': 'qa',
    'qa_done':     'merge',
}

last_stage = None
try:
    with open(log_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            # Nested format: {"type":"...","payload":{...}}
            if 'type' in obj and 'payload' in obj:
                event_type = obj.get('type', '')
                payload    = obj.get('payload', {}) or {}
            else:
                # Flat format: {"event":"...","issue_num":...}
                event_type = obj.get('event', obj.get('type', ''))
                payload    = obj
            if not event_type.endswith('_done'):
                continue
            issue = str(payload.get('issue_num', '') or payload.get('issue', ''))
            pr    = str(payload.get('pr_num',    '') or payload.get('pr',    ''))
            if ticket not in (issue, pr):
                continue
            stage = DONE_TO_STAGE.get(event_type)
            if stage:
                last_stage = stage   # keep iterating to find most recent
except Exception:
    pass

if last_stage:
    print(last_stage)
    sys.exit(0)
sys.exit(1)
PY
    ) || {
        printf 'ERROR: no known-good stage found in event log for ticket #%s\n' "$TICKET_NUM" >&2
        printf '  Pass --to-stage <stage> to force a specific stage.\n' >&2
        exit 2
    }
    REASON="auto-detected from event log (last *_done → $TARGET_STAGE)"
fi

log "target stage: $TARGET_STAGE ($REASON)"

# Resolve the trigger label for the target stage (honours per-project overrides).
TARGET_LABEL=$(loop_trigger_label_for_stage "$SLUG" "$TARGET_STAGE") || {
    printf 'ERROR: could not resolve trigger label for stage %q\n' "$TARGET_STAGE" >&2
    exit 2
}
[ -n "$TARGET_LABEL" ] || {
    printf 'ERROR: empty trigger label for stage %q\n' "$TARGET_STAGE" >&2
    exit 2
}
log "target label: $TARGET_LABEL"

# ---------------------------------------------------------------------------
# Read current labels from the ticket
# ---------------------------------------------------------------------------
# Try PR first (gh pr view exits non-zero if number is an issue); fall back
# to issue view. This distinguishes PRs from issues on all backends.
TICKET_KIND=""
if backend_pr_view "$REPO" "$TICKET_NUM" --json number >/dev/null 2>&1; then
    TICKET_KIND="pr"
elif backend_issue_view "$REPO" "$TICKET_NUM" --json number >/dev/null 2>&1; then
    TICKET_KIND="issue"
else
    printf 'ERROR: ticket #%s not found in %s\n' "$TICKET_NUM" "$REPO" >&2
    exit 1
fi
log "ticket kind: $TICKET_KIND"

CURRENT_LABELS_CSV=""
if [ "$TICKET_KIND" = "pr" ]; then
    CURRENT_LABELS_CSV=$(backend_pr_view "$REPO" "$TICKET_NUM" \
        --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
else
    CURRENT_LABELS_CSV=$(backend_issue_view "$REPO" "$TICKET_NUM" \
        --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
fi

# ---------------------------------------------------------------------------
# Idempotency: check whether target label is already the only pipeline label
# ---------------------------------------------------------------------------
ALREADY_DONE=$(CURRENT="$CURRENT_LABELS_CSV" TARGET="$TARGET_LABEL" \
    STAGE_LABELS="$(loop_pipeline_stage_labels_csv)" python3 - <<'PY'
import os
current      = [l for l in os.environ['CURRENT'].split(',') if l]
target       = os.environ['TARGET']
stage_labels = set(os.environ['STAGE_LABELS'].split(','))
pipeline_on  = [l for l in current if l in stage_labels]
print('yes' if pipeline_on == [target] else 'no')
PY
)

# Labels to remove: every pipeline-stage label that is NOT the target.
LABELS_TO_REMOVE=$(CURRENT="$CURRENT_LABELS_CSV" TARGET="$TARGET_LABEL" \
    STAGE_LABELS="$(loop_pipeline_stage_labels_csv)" python3 - <<'PY'
import os
current      = [l for l in os.environ['CURRENT'].split(',') if l]
target       = os.environ['TARGET']
stage_labels = set(os.environ['STAGE_LABELS'].split(','))
for lbl in current:
    if lbl in stage_labels and lbl != target:
        print(lbl)
PY
)

# ---------------------------------------------------------------------------
# Build comment body
# ---------------------------------------------------------------------------
COMMENT_BODY="**Loop recovery** — operator rolled ticket #${TICKET_NUM} back to stage \`${TARGET_STAGE}\` (\`${TARGET_LABEL}\`).

**Reason:** ${REASON}

Pipeline labels have been updated: all conflicting stage labels removed; \`${TARGET_LABEL}\` applied. The pipeline will re-claim this ticket on the next scanner tick."

# ---------------------------------------------------------------------------
# Dry-run output
# ---------------------------------------------------------------------------
if $DRY_RUN; then
    if [ "$ALREADY_DONE" = "yes" ]; then
        printf '[dry-run] ticket #%s already at stage %s (%s) — no label changes needed\n' \
            "$TICKET_NUM" "$TARGET_STAGE" "$TARGET_LABEL"
    else
        printf '[dry-run] would add label: %s\n' "$TARGET_LABEL"
        if [ -n "$LABELS_TO_REMOVE" ]; then
            while IFS= read -r lbl; do
                printf '[dry-run] would remove label: %s\n' "$lbl"
            done <<< "$LABELS_TO_REMOVE"
        fi
    fi
    printf '[dry-run] would post comment:\n%s\n' "$COMMENT_BODY"
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply label changes
# ---------------------------------------------------------------------------
if [ "$ALREADY_DONE" != "yes" ]; then
    if [ -n "$LABELS_TO_REMOVE" ]; then
        while IFS= read -r lbl; do
            log "removing label: $lbl"
            backend_remove_label "$REPO" "$TICKET_NUM" "$lbl" \
                || log "WARN: failed to remove label $lbl"
        done <<< "$LABELS_TO_REMOVE"
    fi
    log "adding label: $TARGET_LABEL"
    backend_add_label "$REPO" "$TICKET_NUM" "$TARGET_LABEL" \
        || log "WARN: failed to add label $TARGET_LABEL"
else
    log "ticket #$TICKET_NUM already at $TARGET_STAGE ($TARGET_LABEL) — skipping label changes"
fi

# ---------------------------------------------------------------------------
# Post recovery comment (idempotent: skip if last comment already has marker)
# ---------------------------------------------------------------------------
RECOVERY_MARKER="**Loop recovery**"
LAST_COMMENT=""
if [ "$TICKET_KIND" = "pr" ]; then
    LAST_COMMENT=$(backend_pr_view "$REPO" "$TICKET_NUM" \
        --json comments --jq '.comments[-1].body // ""' 2>/dev/null || echo "")
else
    LAST_COMMENT=$(backend_issue_view "$REPO" "$TICKET_NUM" \
        --json comments --jq '.comments[-1].body // ""' 2>/dev/null || echo "")
fi

if printf '%s' "$LAST_COMMENT" | grep -qF "$RECOVERY_MARKER"; then
    log "skipping comment — last comment already contains recovery marker (idempotent)"
else
    log "posting recovery comment on #$TICKET_NUM ($TICKET_KIND)"
    if [ "$TICKET_KIND" = "pr" ]; then
        backend_comment_pr "$REPO" "$TICKET_NUM" "$COMMENT_BODY" \
            || log "WARN: failed to post comment on PR #$TICKET_NUM"
    else
        backend_comment_issue "$REPO" "$TICKET_NUM" "$COMMENT_BODY" \
            || log "WARN: failed to post comment on issue #$TICKET_NUM"
    fi
fi

log "done: ticket #$TICKET_NUM recovered to stage $TARGET_STAGE ($TARGET_LABEL)"
