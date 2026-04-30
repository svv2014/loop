#!/usr/bin/env bash
# reconcile.sh — one-shot startup audit of in-flight pipeline state.
#
# Runs once at launchd load (RunAtLoad), before the first scanner tick.
# Iterates every project in config/projects.yaml and lists open issues +
# PRs through the backend abstraction so downstream child issues can plug
# in concrete drift / orphan / blocked checks.
#
# Today this entrypoint is intentionally observational: it counts what it
# sees and emits a structured one-line summary so log aggregation can
# track startup health. All mutation logic lives in scanner/reconciler.sh
# (the recurring 15-min sweep) and will be incrementally subsumed via
# follow-up child issues of epic #154.
#
# Modes:
#   reconcile.sh                 # audit all projects
#   reconcile.sh --slug <slug>   # limit to one project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-reconcile.log"
ONLY_SLUG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --slug) ONLY_SLUG="$2"; shift 2 ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local line; line="[$(date '+%Y-%m-%d %H:%M:%S')] [reconcile] $*"
    if [ -t 2 ]; then
        printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

# Counters for the summary line. Concrete repair logic plugs in later;
# today this entrypoint just observes and reports zero across the board.
DRIFT_REPAIRED=0
ORPHANS_GC=0
BLOCKED_REPORTED=0

audit_project() {
    local slug="$1"
    loop_load_project "$slug" || { log "skip $slug (config error)"; return 0; }
    loop_load_backend

    local issues_json prs_json issue_count pr_count
    issues_json=$(backend_list_open_issues_raw "$REPO" "" 2>/dev/null || echo "[]")
    prs_json=$(backend_list_open_prs_raw "$REPO" 2>/dev/null || echo "[]")
    issue_count=$(printf '%s' "$issues_json" \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
    pr_count=$(printf '%s' "$prs_json" \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)

    log "[$slug] $REPO: open_issues=$issue_count open_prs=$pr_count"
}

log "=== reconcile start (only_slug=${ONLY_SLUG:-<all>}) ==="

if [ -n "$ONLY_SLUG" ]; then
    audit_project "$ONLY_SLUG"
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        audit_project "$slug"
    done < <(loop_list_slugs)
fi

log "reconcile: drift_repaired=${DRIFT_REPAIRED} orphans_gc=${ORPHANS_GC} blocked_reported=${BLOCKED_REPORTED}"
log "=== reconcile done ==="
