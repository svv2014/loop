#!/usr/bin/env bash
# scanner.sh — Loop event fan-out scanner.
# For each project in config/projects.yaml, poll GitHub for actionable items
# and emit events to handlers (direct or via event queue). One scanner, many projects.
#
# Usage:
#   scanner.sh            # continuous mode (5-min cadence, suitable for launchd (macOS) or cron (Linux))
#   scanner.sh --once     # single sweep
#   scanner.sh --dry-run  # print events to stdout without queueing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"

LOCK_FILE="/tmp/loop-scanner.lock"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner.log"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
BOBA_EVENT_CLIENT="${LOOP_EVENT_CLIENT:-}"
HANDLER_TIMEOUT="${LOOP_HANDLER_TIMEOUT:-7200}"

DRY_RUN=false
ONCE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    ONCE=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -15
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] $*"; }

# Map event type to handler script (dispatch_direct mode).
dispatch_direct() {
    local json="$1"
    local event_type
    event_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")
    local handler
    case "$event_type" in
        loop.po_review)  handler="$LOOP_ROOT/scripts/po-handler.sh" ;;
        loop.dev_issue)  handler="$LOOP_ROOT/scripts/dev-handler.sh" ;;
        loop.pr_review)  handler="$LOOP_ROOT/scripts/review-handler.sh" ;;
        loop.dev_rework) handler="$LOOP_ROOT/scripts/dev-rework-handler.sh" ;;
        loop.pr_qa)      handler="$LOOP_ROOT/scripts/qa-handler.sh" ;;
        loop.pr_merge)   handler="$LOOP_ROOT/scripts/merge-handler.sh" ;;
        *) log "WARN: no handler for event type '$event_type'"; return 1 ;;
    esac
    local effective_timeout="${HANDLER_TIMEOUT_SECONDS:-$HANDLER_TIMEOUT}"
    LOOP_EVENT_JSON="$json" nohup timeout "$effective_timeout" "$handler" >> "$LOOP_LOG_DIR/loop-scanner.log" 2>&1 &
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "Already running (PID $pid). Exiting."
            exit 0
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# Dedup cache — prevent emitting the same event every tick.
# Events are keyed by "type:slug:number". Cache clears on scanner restart.
DEDUP_DIR="/tmp/loop-scanner-dedup"
mkdir -p "$DEDUP_DIR"

_dedup_key() {
    echo "$1" | md5sum | cut -d' ' -f1
}

# emit <json> <dedup_id>
# Only emits if this dedup_id hasn't been emitted in the last 30 minutes.
# Dispatches via event queue (LOOP_DISPATCH_MODE=event-queue) or direct script (default).
emit() {
    local json="$1"
    local dedup_id="${2:-}"
    if $DRY_RUN; then
        echo "DRY-RUN emit: $json"
        return 0
    fi
    # Dedup check: skip if emitted recently (30m = 1800s)
    if [ -n "$dedup_id" ]; then
        local key_file
        key_file="$DEDUP_DIR/$(_dedup_key "$dedup_id")"
        if [ -f "$key_file" ]; then
            local age
            age=$(( $(date +%s) - $(stat -f%m "$key_file" 2>/dev/null || echo 0) ))
            if [ "$age" -lt 1800 ]; then
                return 0  # Already emitted recently, skip
            fi
        fi
    fi
    if [ "${LOOP_DISPATCH_MODE:-direct}" = "event-queue" ] && [ -n "$BOBA_EVENT_CLIENT" ]; then
        if ! "$BOBA_EVENT_CLIENT" queue "$json" >/dev/null 2>>"$LOG_FILE"; then
            log "WARN: failed to queue event: $json"
            return 1
        fi
    else
        if ! dispatch_direct "$json"; then
            log "WARN: failed to dispatch event: $json"
            return 1
        fi
    fi
    # Mark as emitted
    if [ -n "$dedup_id" ]; then
        touch "$DEDUP_DIR/$(_dedup_key "$dedup_id")"
    fi
}

# Dedup marker: has this issue/PR already been handed to a handler?
# Checks both old and new label names for each stage.
issue_is_claimed() {
    local repo="$1" num="$2"
    backend_issue_has_any_label "$repo" "$num" \
        in-progress build blocked \
        review-pending needs-review \
        ready-for-qa needs-qa \
        qa-pass approved \
        'done'
}

# author_is_allowed <author_login>
# Returns 0 (true) if ALLOWED_AUTHORS is empty or contains the author.
author_is_allowed() {
    local author="$1"
    [ -z "${ALLOWED_AUTHORS:-}" ] && return 0
    local IFS=','
    for a in $ALLOWED_AUTHORS; do
        [ "$a" = "$author" ] && return 0
    done
    return 1
}

pr_is_claimed_for_review() {
    local repo="$1" num="$2"
    backend_pr_has_any_label "$repo" "$num" \
        in-review \
        ready-for-qa needs-qa \
        qa-pass approved \
        'done'
}

pr_is_claimed_for_qa() {
    local repo="$1" num="$2"
    backend_pr_has_any_label "$repo" "$num" qa-pass approved 'done'
}

pr_is_claimed_for_rework() {
    local repo="$1" num="$2"
    backend_pr_has_any_label "$repo" "$num" in-rework blocked
}

# count_inflight_prs <repo>
# Count open PRs that carry at least one pipeline label.
count_inflight_prs() {
    local repo="$1"
    local raw
    raw=$(backend_list_open_prs_raw "$repo")
    printf '%s\n' "$raw" | python3 -c "
import json, sys
pipeline_labels = {
    'in-progress', 'build', 'review-pending', 'needs-review', 'in-review',
    'ready-for-qa', 'needs-qa', 'in-rework', 'changes-requested', 'needs-rework',
    'qa-fail', 'qa-failed', 'qa-pass', 'approved',
}
prs = json.load(sys.stdin)
print(sum(
    1 for pr in prs
    if any(l.get('name', '') in pipeline_labels for l in pr.get('labels', []))
))
"
}

scan_project() {
    local slug="$1"
    loop_load_project "$slug" || { log "skip: slug '$slug' unloadable"; return; }
    loop_load_backend
    local repo="$REPO"

    local _wf
    _wf=$(loop_workflow_for_project "$slug")
    log "scan: $slug ($repo) workflow=$_wf"

    # --- po-review issues: rough ideas awaiting PO expansion -----------------
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        local num title url
        num=$(echo "$row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(echo "$row"  | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(echo "$row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        local author
        author=$(echo "$row" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author',''))")
        if ! author_is_allowed "$author"; then
            log "skip po-review #$num: author '$author' not in ALLOWED_AUTHORS"
            continue
        fi
        if issue_is_claimed "$repo" "$num"; then
            continue
        fi
        local evt
        evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.po_review',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'issue_number': int(sys.argv[3]),
        'issue_title': sys.argv[4],
        'issue_url': sys.argv[5],
    }
}))
" "$slug" "$repo" "$num" "$title" "$url")
        log "emit loop.po_review #$num $title"
        emit "$evt" "po_review:${slug}:${num}"
    done < <(backend_list_issues_with_label "$repo" "$(loop_label_for "$slug" "po-review")")

    # --- dev issues: workflow-driven label (canonical 'plan'). The project's
    # active workflow + label overrides decide the actual label name (e.g.
    # 'dev' for projects on `workflow: current`, 'plan' for `default`).
    local _inflight _slots _rows_tmp _seen_tmp _emitted _di_num _di_title _di_url _di_unmet _di_evt
    _inflight=$(count_inflight_prs "$repo")
    _slots=$(( MAX_CONCURRENT_PRS - _inflight ))
    log "dev_issue: max=${MAX_CONCURRENT_PRS} in-flight=${_inflight} slots=${_slots}"

    if [ "$_slots" -le 0 ]; then
        log "skip dev_issue for $slug: ${_inflight}/${MAX_CONCURRENT_PRS} pipeline PRs in flight"
    else
        _rows_tmp=$(mktemp)
        _seen_tmp=$(mktemp)

        # Collect from the project's resolved 'plan' label.
        # Already priority-sorted by backend_list_issues_with_label.
        while IFS= read -r _r; do
            [ -z "$_r" ] && continue
            _di_num=$(printf '%s' "$_r" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
            if ! grep -qxF "$_di_num" "$_seen_tmp" 2>/dev/null; then
                printf '%s\n' "$_di_num" >> "$_seen_tmp"
                printf '%s\n' "$_r" >> "$_rows_tmp"
            fi
        done < <(backend_list_issues_with_label "$repo" "$(loop_label_for "$slug" "plan")")

        # Re-sort the combined list by (priority, issue_number) so that cross-label
        # ordering is correct (e.g. a p0 in 'plan' beats a p2 in 'dev').
        local _sorted_tmp
        _sorted_tmp=$(mktemp)
        _ROWS_FILE="$_rows_tmp" python3 <<'PY' > "$_sorted_tmp"
import json, sys, os
PRIORITY = {'p0-critical': 0, 'p1-high': 1, 'p2-medium': 2, 'p3-low': 3}
rows = []
with open(os.environ['_ROWS_FILE']) as fh:
    for line in fh:
        line = line.rstrip('\n')
        if not line:
            continue
        obj = json.loads(line)
        labels = obj.get('labels', [])
        p = min((PRIORITY[l] for l in labels if l in PRIORITY), default=4)
        rows.append((p, obj['number'], line))
rows.sort(key=lambda x: (x[0], x[1]))
for _, _, line in rows:
    print(line)
PY
        mv "$_sorted_tmp" "$_rows_tmp"

        _emitted=0
        while IFS= read -r _row; do
            [ "$_emitted" -ge "$_slots" ] && break
            [ -z "$_row" ] && continue
            _di_num=$(printf '%s' "$_row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
            _di_title=$(printf '%s' "$_row"  | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
            _di_url=$(printf '%s' "$_row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
            local _di_author
            _di_author=$(printf '%s' "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author',''))")
            if ! author_is_allowed "$_di_author"; then
                log "skip dev_issue #$_di_num: author '$_di_author' not in ALLOWED_AUTHORS"
                continue
            fi
            if issue_is_claimed "$repo" "$_di_num"; then
                continue
            fi
            # Dependency gate: defer if the issue body declares unmet deps in
            # its "## Dependencies" section. Pickup resumes automatically once deps close.
            _di_unmet=$(backend_issue_unmet_deps "$repo" "$_di_num" 2>/dev/null || true)
            if [ -n "$_di_unmet" ]; then
                log "defer loop.dev_issue #$_di_num $_di_title — unmet deps: $(printf '%s' "$_di_unmet" | tr '\n' ' ')"
                continue
            fi
            _di_evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.dev_issue',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'issue_number': int(sys.argv[3]),
        'issue_title': sys.argv[4],
        'issue_url': sys.argv[5],
    }
}))
" "$slug" "$repo" "$_di_num" "$_di_title" "$_di_url")
            log "emit loop.dev_issue #$_di_num $_di_title"
            emit "$_di_evt" "dev_issue:${slug}:${_di_num}"
            _emitted=$(( _emitted + 1 ))
        done < "$_rows_tmp"
        rm -f "$_rows_tmp" "$_seen_tmp"
    fi

    # --- PRs: review-pending / needs-review (new name); shared dedup key -----
    _emit_pr_review() {
        local _row="$1"
        [ -z "$_row" ] && return 0
        local num title url
        num=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(echo "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        if pr_is_claimed_for_review "$repo" "$num"; then
            return 0
        fi
        local evt
        evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.pr_review',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'pr_number': int(sys.argv[3]),
        'pr_title': sys.argv[4],
        'pr_url': sys.argv[5],
    }
}))
" "$slug" "$repo" "$num" "$title" "$url")
        log "emit loop.pr_review PR#$num $title"
        emit "$evt" "pr_review:${slug}:${num}"
    }
    while IFS= read -r row; do _emit_pr_review "$row"; done \
        < <(backend_list_prs_with_label "$repo" "$(loop_label_for "$slug" "needs-review")")

    # --- PRs: changes-requested / needs-rework (new name) → dev_rework ------
    _emit_dev_rework_cr() {
        local _row="$1"
        [ -z "$_row" ] && return 0
        local num title url
        num=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(echo "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        if pr_is_claimed_for_rework "$repo" "$num"; then
            return 0
        fi
        local evt
        evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.dev_rework',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'pr_number': int(sys.argv[3]),
        'pr_title': sys.argv[4],
        'pr_url': sys.argv[5],
    }
}))
" "$slug" "$repo" "$num" "$title" "$url")
        log "emit loop.dev_rework PR#$num $title"
        emit "$evt" "dev_rework:${slug}:${num}"
    }
    while IFS= read -r row; do _emit_dev_rework_cr "$row"; done \
        < <(backend_list_prs_with_label "$repo" "$(loop_label_for "$slug" "needs-rework")")

    # --- PRs: qa-fail / qa-failed (new name) → dev_rework -------------------
    _emit_dev_rework_qa() {
        local _row="$1"
        [ -z "$_row" ] && return 0
        local num title url
        num=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(echo "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        if pr_is_claimed_for_rework "$repo" "$num"; then
            return 0
        fi
        local evt
        evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.dev_rework',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'pr_number': int(sys.argv[3]),
        'pr_title': sys.argv[4],
        'pr_url': sys.argv[5],
        'rework_context': 'qa-fail',
    }
}))
" "$slug" "$repo" "$num" "$title" "$url")
        log "emit loop.dev_rework (qa-fail) PR#$num $title"
        emit "$evt" "dev_rework_qa:${slug}:${num}"
    }
    while IFS= read -r row; do _emit_dev_rework_qa "$row"; done \
        < <(backend_list_prs_with_label "$repo" "$(loop_label_for "$slug" "qa-fail")")

    # --- PRs: ready-for-qa / needs-qa (new name); shared dedup key -----------
    _emit_pr_qa() {
        local _row="$1"
        [ -z "$_row" ] && return 0
        local num title url
        num=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(echo "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        if pr_is_claimed_for_qa "$repo" "$num"; then
            return 0
        fi
        local evt
        evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.pr_qa',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'pr_number': int(sys.argv[3]),
        'pr_title': sys.argv[4],
        'pr_url': sys.argv[5],
    }
}))
" "$slug" "$repo" "$num" "$title" "$url")
        log "emit loop.pr_qa PR#$num $title"
        emit "$evt" "pr_qa:${slug}:${num}"
    }
    while IFS= read -r row; do _emit_pr_qa "$row"; done \
        < <(backend_list_prs_with_label "$repo" "$(loop_label_for "$slug" "needs-qa")")

    # --- PRs: qa-pass / approved (new name); shared dedup key ---------------
    _emit_pr_merge() {
        local _row="$1"
        [ -z "$_row" ] && return 0
        local num title url
        num=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(echo "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(echo "$_row"   | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        local evt
        evt=$(python3 -c "
import json,sys
print(json.dumps({
    'type':'loop.pr_merge',
    'payload':{
        'slug': sys.argv[1],
        'repo': sys.argv[2],
        'pr_number': int(sys.argv[3]),
        'pr_title': sys.argv[4],
        'pr_url': sys.argv[5],
    }
}))
" "$slug" "$repo" "$num" "$title" "$url")
        log "emit loop.pr_merge PR#$num $title"
        emit "$evt" "pr_merge:${slug}:${num}"
    }
    while IFS= read -r row; do _emit_pr_merge "$row"; done \
        < <(backend_list_prs_with_label "$repo" "$(loop_label_for "$slug" "qa-pass")")
}

run_once() {
    log "=== scan tick start ==="
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        scan_project "$slug" || log "scan_project $slug failed (continuing)"
    done < <(loop_list_slugs)
    log "=== scan tick done ==="
}

acquire_lock

log "Loop v${LOOP_VERSION:-unknown} starting (poll=${POLL_INTERVAL}s, dry=$DRY_RUN, once=$ONCE)"

if $ONCE || $DRY_RUN; then
    run_once
    exit 0
fi

log "starting continuous scanner (interval=${POLL_INTERVAL}s)"
while true; do
    run_once
    sleep "$POLL_INTERVAL"
done
