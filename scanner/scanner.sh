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
# shellcheck source=../lib/labels.sh
source "$LOOP_ROOT/lib/labels.sh"
# shellcheck source=../lib/jobs.sh
source "$LOOP_ROOT/lib/jobs.sh"
# workflow helpers (loop_polled_labels, loop_handler_for_label, loop_stage_trigger,
# loop_workflow_for_project) are already loaded via lib/env.sh → lib/workflow.sh.
# The line below is for shellcheck only.
# shellcheck source=../lib/workflow.sh

LOCK_FILE="/tmp/loop-scanner.lock"
LOG_FILE="${LOOP_LOG_DIR}/loop-scanner.log"
POLL_INTERVAL="${LOOP_SCANNER_INTERVAL:-300}"
BOBA_EVENT_CLIENT="${LOOP_EVENT_CLIENT:-}"
HANDLER_TIMEOUT="${LOOP_HANDLER_TIMEOUT:-7200}"

# SIGHUP-reopen contract (#194): logrotate-style tools truncate or rename
# the on-disk log file. The launchd plist redirects stdout/stderr to a
# path, but the running process holds an open FD to the original inode —
# after rotation the process keeps writing to a deleted inode and the
# on-disk file appears 0 bytes (observed today, hid scanner activity for
# hours). On SIGHUP, reopen FDs 1+2 against the path so writes resume to
# the current inode.
_scanner_reopen_log() {
    if [ -n "${LOG_FILE:-}" ]; then
        exec 1>>"$LOG_FILE" 2>>"$LOG_FILE" || true
    fi
}
trap '_scanner_reopen_log; echo "[$(date "+%Y-%m-%d %H:%M:%S")] [scanner] SIGHUP — log fds reopened"' HUP

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

# _scanner_jobs_enqueue <slug> <stage> <num>
# Best-effort dual-write to the jobs table alongside the legacy label-event path.
# Skipped when LOOP_JOBS_ENQUEUE=0 or --dry-run.
_scanner_jobs_enqueue() {
    local slug="$1" stage="$2" num="$3"
    [[ "${LOOP_JOBS_ENQUEUE:-1}" == "1" ]] || return 0
    $DRY_RUN && return 0
    jobs_enqueue "$slug" "$stage" "$num" >/dev/null \
        || log "WARN: jobs_enqueue failed for ${stage}:${slug}:${num}"
}

# _stage_cap <event_type>
# Resolves the per-tick emit cap for a given event type.
# Checks MAX_CONCURRENT_HANDLERS_<STAGE> (event type uppercased, dots → underscores),
# then MAX_CONCURRENT_HANDLERS, then defaults to 1.
_stage_cap() {
    local stage="$1"
    local stage_upper
    stage_upper=$(printf '%s' "$stage" | tr '[:lower:].' '[:upper:]_')
    local var="MAX_CONCURRENT_HANDLERS_${stage_upper}"
    printf '%s' "${!var:-${MAX_CONCURRENT_HANDLERS:-1}}"
}

# _handler_to_event_type <handler_base_name>
# Maps a workflow handler name (from workflow YAML) to a loop event type string.
_handler_to_event_type() {
    case "$1" in
        po-handler)          echo "loop.po_review" ;;
        dev-handler)         echo "loop.dev_issue" ;;
        senior-dev-handler)  echo "loop.senior_dev" ;;
        review-handler)      echo "loop.pr_review" ;;
        dev-rework-handler)  echo "loop.dev_rework" ;;
        qa-handler)          echo "loop.pr_qa" ;;
        merge-handler)       echo "loop.pr_merge" ;;
        *)                   echo "loop.$1" ;;
    esac
}

# Map event type to handler script (dispatch_direct mode).
dispatch_direct() {
    local json="$1"
    local event_type
    event_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")
    local handler
    case "$event_type" in
        loop.po_review)   handler="$LOOP_ROOT/scripts/po-handler.sh" ;;
        loop.dev_issue)   handler="$LOOP_ROOT/scripts/dev-handler.sh" ;;
        loop.senior_dev)  handler="$LOOP_ROOT/scripts/senior-dev-handler.sh" ;;
        loop.pr_review)   handler="$LOOP_ROOT/scripts/review-handler.sh" ;;
        loop.dev_rework)  handler="$LOOP_ROOT/scripts/dev-rework-handler.sh" ;;
        loop.pr_qa)       handler="$LOOP_ROOT/scripts/qa-handler.sh" ;;
        loop.pr_merge)    handler="$LOOP_ROOT/scripts/merge-handler.sh" ;;
        *) log "WARN: no handler for event type '$event_type'"; return 1 ;;
    esac
    local effective_timeout="${HANDLER_TIMEOUT_SECONDS:-$HANDLER_TIMEOUT}"
    # Wrap with the budget tally helper so each handler's wall-clock time is
    # accumulated into ${LOOP_LOG_DIR}/budget/YYYYMMDD.counter. Wrapper exits
    # with the handler's exit code so timeout(1) and scanner behavior are unchanged.
    LOOP_EVENT_JSON="$json" nohup timeout "$effective_timeout" \
        "$LOOP_ROOT/scripts/_handler_with_budget.sh" "$handler" \
        >> "$LOOP_LOG_DIR/loop-scanner.log" 2>&1 &
}

# _budget_exceeded — returns 0 (true) if today's accumulated handler-seconds
# meet or exceed LOOP_DAILY_HANDLER_BUDGET_SECONDS. Empty/unset env var =
# disabled (always returns 1).
_budget_counter_path() { printf '%s/budget/%s.counter' "${LOOP_LOG_DIR:?LOOP_LOG_DIR must be set}" "$(date +%Y%m%d)"; }
_budget_exceeded() {
    [ -n "${LOOP_DAILY_HANDLER_BUDGET_SECONDS:-}" ] || return 1
    local spent
    spent=$(cat "$(_budget_counter_path)" 2>/dev/null || echo 0)
    [ "$spent" -ge "$LOOP_DAILY_HANDLER_BUDGET_SECONDS" ]
}

acquire_lock() {
    # Atomic create — POSIX noclobber fails if the file already exists.
    if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
        trap 'rm -f "$LOCK_FILE"' EXIT
        return 0
    fi
    # File already exists — check if the holder is still alive.
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "Already running (PID $pid). Exiting."
        exit 0
    fi
    # Stale lock — holder PID is dead; remove and retry once.
    rm -f "$LOCK_FILE"
    if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
        trap 'rm -f "$LOCK_FILE"' EXIT
        return 0
    fi
    # Another process won the race on the retry — exit cleanly.
    log "Lock unavailable after stale-PID recovery. Exiting."
    exit 0
}

# Dedup cache — prevent emitting the same event every tick.
# Events are keyed by "type:slug:number". Cache clears on scanner restart.
DEDUP_DIR="/tmp/loop-scanner-dedup"
mkdir -p "$DEDUP_DIR"

_dedup_key() {
    # Always returns a bare hex hash with no whitespace. Previously md5sum
    # output (the linux/coreutils form) leaked '  -' into the dedup
    # filename, making manual ops (rm a stuck entry) painful and the
    # macOS-fallback to `md5 -q` unreachable. Use ${hash%% *} to keep
    # only the first whitespace-separated token (the hex digest).
    local hash
    hash=$(printf '%s' "$1" | md5sum 2>/dev/null) \
        || hash=$(printf '%s' "$1" | md5 -q 2>/dev/null) \
        || hash=$(printf '%s' "$1" | sha256sum | cut -c1-32)
    printf '%s' "${hash%% *}"
}

# Stage-age cache — tracks when a PR first appeared at a given stage.
# Prevents a stuck PR from winning the per-tick cap slot indefinitely.
# Key: "stage-age:<event_type>:<slug>:<num>". Auto-expires after the cooloff
# window (LOOP_STAGE_AGE_COOLOFF_MULTIPLIER × LOOP_MAX_AGE_IN_STAGE_SECONDS,
# default 6h) so a quarantined PR gets one more dispatch attempt. Clear
# /tmp/loop-stage-age/ manually to force immediate retry.
STAGE_AGE_DIR="/tmp/loop-stage-age"
mkdir -p "$STAGE_AGE_DIR"

# _stage_age_exceeded <key> <max_seconds> <cooloff_seconds>
# Returns 0 (true) if this key was recorded more than max_seconds ago AND the
# cooloff window has not yet elapsed (i.e., the PR is quarantined).
# Once age >= cooloff_seconds the tracking file is deleted so the PR gets one
# more dispatch attempt; if it stalls again a fresh quarantine begins.
# Side-effect: creates the tracking file on first call for a new key.
_stage_age_exceeded() {
    local key="$1" max_age="$2" cooloff="$3"
    local key_file
    key_file="$STAGE_AGE_DIR/$(_dedup_key "$key")"
    if [ ! -f "$key_file" ]; then
        touch "$key_file"
        return 1
    fi
    local age
    age=$(( $(date +%s) - $(stat -f%m "$key_file" 2>/dev/null || stat -c%Y "$key_file" 2>/dev/null || echo 0) ))
    if [ "$age" -ge "$cooloff" ]; then
        rm -f "$key_file"
        return 1
    fi
    [ "$age" -ge "$max_age" ]
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
            age=$(( $(date +%s) - $(stat -f%m "$key_file" 2>/dev/null || stat -c%Y "$key_file" 2>/dev/null || echo 0) ))
            if [ "$age" -lt 1800 ]; then
                log "skip (dedup, age=${age}s): $dedup_id"
                return 0
            fi
        fi
    fi
    log "emit: $dedup_id"
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

# issue_is_claimed <slug> <repo> <num>
# Returns 0 if the issue has been dispatched or moved past the issue stage.
# Claimed labels are derived from the project's workflow PR trigger labels
# plus a fixed set of handler-set operational labels (in-progress, build, blocked).
#
# A PR trigger label that is *also* an issue trigger in the same workflow
# (e.g. `needs-dev` is both the issue dev trigger and the PR rework trigger
# in the default workflow) must NOT count as a claim — otherwise an issue
# carrying its own dev trigger is silently filtered out and never dispatched.
issue_is_claimed() {
    local slug="$1" repo="$2" num="$3"
    local issue_trigger_labels pr_trigger_labels filtered_pr_labels
    issue_trigger_labels=$(loop_polled_labels "$slug" issue 2>/dev/null | tr '\n' ' ')
    pr_trigger_labels=$(loop_polled_labels "$slug" pr 2>/dev/null)
    # Subtract issue triggers from the PR trigger set.
    filtered_pr_labels=""
    while IFS= read -r _lbl; do
        [ -z "$_lbl" ] && continue
        case " $issue_trigger_labels " in
            *" $_lbl "*) continue ;;
        esac
        filtered_pr_labels="$filtered_pr_labels $_lbl"
    done <<< "$pr_trigger_labels"
    # shellcheck disable=SC2086
    backend_issue_has_any_label "$repo" "$num" \
        in-progress build blocked 'done' \
        ${filtered_pr_labels}
}

# _pr_downstream_labels <slug> <from_label>
# Returns space-separated PR stage trigger labels that appear after from_label
# in the project's workflow. Used to determine whether a PR has already moved
# past the stage we are about to dispatch.
_pr_downstream_labels() {
    local slug="$1" from_label="$2"
    local found=false
    local result=""
    while IFS= read -r lbl; do
        if $found; then
            result="$result $lbl"
        elif [ "$lbl" = "$from_label" ]; then
            found=true
        fi
    done < <(loop_polled_labels "$slug" pr 2>/dev/null)
    echo "$result"
}

# author_is_allowed <author_login> [labels_space_separated]
# Returns 0 (true) if any of the following holds:
#   - ALLOWED_AUTHORS is empty (gate disabled)
#   - the ticket carries the `operator-approved` label (per-ticket override)
#   - the author appears in ALLOWED_AUTHORS
# The label override is a documentation/operator contract — enforcement of who
# may apply the label is done by GitHub repo permissions, not loop code.
# See docs/security.md for the override semantics.
author_is_allowed() {
    local author="$1"
    local labels="${2:-}"
    case " $labels " in
        *" operator-approved "*) return 0 ;;
    esac
    [ -z "${ALLOWED_AUTHORS:-}" ] && return 0
    local IFS=','
    for a in $ALLOWED_AUTHORS; do
        [ "$a" = "$author" ] && return 0
    done
    return 1
}

# _sort_rows_by_priority — read newline-delimited JSON rows from stdin,
# write them back to stdout sorted by (priority-label, number ASC).
# Priority order: p0-critical > p1-high > p2-medium > p3-low > unlabeled.
# Tiebreaker: lower issue/PR number (proxy for older created_at, since GitHub
# IDs are monotonic — and `created_at` requires an extra API field).
_sort_rows_by_priority() {
    python3 -c '
import json, sys
PRIORITY = {"p0-critical": 0, "p1-high": 1, "p2-medium": 2, "p3-low": 3}
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    labels = obj.get("labels") or []
    p = min((PRIORITY[l] for l in labels if l in PRIORITY), default=4)
    rows.append((p, obj.get("number", 0), line))
rows.sort(key=lambda x: (x[0], x[1]))
for _, _, line in rows:
    print(line)
'
}

# count_inflight_issues <slug> <repo> [exclude_label]
# Count distinct open issues that carry at least one pipeline label (workflow
# issue or PR trigger labels, plus handler-set in-flight labels in-progress/blocked).
# Used by the per-project `pipeline_slots` gate.
#
# <exclude_label> (optional): a label to OMIT from the pipeline set. The caller
# passes the first-stage issue trigger here so the queue waiting for that
# stage isn't counted against the gate — otherwise a backlog of e.g. needs-po
# tickets self-blocks the very stage that would drain them (#267 follow-up).
count_inflight_issues() {
    local slug="$1" repo="$2" exclude="${3:-}"
    local labels
    labels=$(
        {
            loop_polled_labels "$slug" issue 2>/dev/null
            loop_polled_labels "$slug" pr 2>/dev/null
            printf 'in-progress\nblocked\n'
        } | awk -v ex="$exclude" 'NF && $0 != ex && !seen[$0]++'
    )
    local seen_tmp
    seen_tmp=$(mktemp)
    local lbl
    while IFS= read -r lbl; do
        [ -z "$lbl" ] && continue
        while IFS= read -r _r; do
            [ -z "$_r" ] && continue
            local _n
            _n=$(printf '%s' "$_r" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)
            [ -z "$_n" ] && continue
            printf '%s\n' "$_n" >> "$seen_tmp"
        done < <(backend_list_issues_with_label "$repo" "$lbl" 2>/dev/null || true)
    done <<< "$labels"
    local n
    n=$(awk 'NF' "$seen_tmp" | sort -u | wc -l | tr -d ' ')
    rm -f "$seen_tmp"
    echo "${n:-0}"
}

# count_inflight_prs <slug> <repo>
# Count open PRs that carry at least one pipeline label.
# Pipeline labels are derived from the project's workflow PR trigger labels
# plus handler-set in-flight labels (in-progress, in-review, deprecated rework-alias).
count_inflight_prs() {
    local slug="$1" repo="$2"
    local pr_labels
    pr_labels=$(loop_polled_labels "$slug" pr 2>/dev/null | tr '\n' ' ')
    local raw
    raw=$(backend_list_open_prs_raw "$repo")
    PIPELINE_LABELS="in-progress in-review ${LOOP_LABEL_DEPRECATED_IN_REWORK} ${pr_labels}" \
    printf '%s\n' "$raw" | python3 -c "
import json, sys, os
pipeline_labels = set(os.environ.get('PIPELINE_LABELS', '').split())
prs = json.load(sys.stdin)
print(sum(
    1 for pr in prs
    if any(l.get('name', '') in pipeline_labels for l in pr.get('labels', []))
))
"
}

# _emit_issue_event <type> <slug> <repo> <num> <title> <url>
# Build and print an issue event JSON string.
_emit_issue_event() {
    local type="$1" slug="$2" repo="$3" num="$4" title="$5" url="$6"
    python3 -c "
import json,sys
print(json.dumps({
    'type': sys.argv[1],
    'payload': {
        'slug': sys.argv[2],
        'repo': sys.argv[3],
        'issue_number': int(sys.argv[4]),
        'issue_title': sys.argv[5],
        'issue_url': sys.argv[6],
    }
}))
" "$type" "$slug" "$repo" "$num" "$title" "$url"
}

# _emit_pr_event <type> <slug> <repo> <num> <title> <url> [extra_key] [extra_val]
# Build and print a PR event JSON string. extra_key/extra_val add one optional payload field.
_emit_pr_event() {
    local type="$1" slug="$2" repo="$3" num="$4" title="$5" url="$6"
    local extra_key="${7:-}" extra_val="${8:-}"
    python3 -c "
import json,sys
p = {
    'slug': sys.argv[2],
    'repo': sys.argv[3],
    'pr_number': int(sys.argv[4]),
    'pr_title': sys.argv[5],
    'pr_url': sys.argv[6],
}
if sys.argv[7]:
    p[sys.argv[7]] = sys.argv[8]
print(json.dumps({'type': sys.argv[1], 'payload': p}))
" "$type" "$slug" "$repo" "$num" "$title" "$url" "$extra_key" "$extra_val"
}

# _scan_issue_stage <slug> <repo> <trigger_label> <handler> <event_type>
# Handles a single issue stage. dev-handler gets slot/priority/dep-gate logic;
# all other handlers get a simple poll-and-emit loop.
_scan_issue_stage() {
    local slug="$1" repo="$2" trigger_label="$3" handler="$4" event_type="$5"

    if [ "$handler" = "dev-handler" ]; then
        _scan_dev_issue_stage "$slug" "$repo" "$trigger_label" "$event_type"
        return
    fi

    # Simple issue stage (e.g. po-handler, senior-dev-handler).
    # Cap new emits per tick so a project with many ready issues doesn't fan
    # out to N parallel handler runs every tick. Cap is per-stage configurable.
    local _cap; _cap=$(_stage_cap "$event_type")
    local _emitted=0
    log "${event_type}: max=${_cap} (per-tick emit cap)"
    while IFS= read -r row; do
        [ "$_emitted" -ge "$_cap" ] && break
        [ -z "$row" ] && continue
        local num title url author
        num=$(printf '%s' "$row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(printf '%s' "$row"  | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(printf '%s' "$row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        author=$(printf '%s' "$row" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author',''))")
        local labels
        labels=$(printf '%s' "$row" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('labels') or []))")
        if ! author_is_allowed "$author" "$labels"; then
            log "skip $event_type #$num: author '$author' not in ALLOWED_AUTHORS"
            continue
        fi
        if issue_is_claimed "$slug" "$repo" "$num"; then
            continue
        fi
        local evt
        evt=$(_emit_issue_event "$event_type" "$slug" "$repo" "$num" "$title" "$url")
        emit "$evt" "${event_type}:${slug}:${num}"
        _scanner_jobs_enqueue "$slug" "$event_type" "$num"
        # Count attempts, not just fresh emits: a deduped ticket means its
        # handler ran in the last 30 min and is likely still in flight, so
        # it should consume a concurrency slot too.
        _emitted=$(( _emitted + 1 ))
    done < <(backend_list_issues_with_label "$repo" "$trigger_label" | _sort_rows_by_priority)
}

# _scan_has_open_pr_for_issue <repo> <issue_num>
# Prints the first open PR number whose body declares "Closes #<issue_num>"
# (case-insensitive, exact number match — same pattern as reconciler).
# Prints nothing and returns 1 if none found or on gh error (fail-open).
_scan_has_open_pr_for_issue() {
    local repo="$1" issue_num="$2"
    local candidates
    candidates=$(gh pr list --repo "$repo" --state open \
        --search "closes #${issue_num} in:body" \
        --json number,body 2>/dev/null) || return 1
    printf '%s\n' "$candidates" | python3 -c "
import json, re, sys
issue_num = int(sys.argv[1])
CLOSES_RE = re.compile(
    r'(?i)(?:clos(?:e|es|ed)|fix(?:es|ed)?|resolv(?:e|es|ed)?)\s+#(\d+)'
)
prs = json.load(sys.stdin)
for pr in prs:
    body = pr.get('body') or ''
    for m in CLOSES_RE.finditer(body):
        if int(m.group(1)) == issue_num:
            print(pr['number'])
            sys.exit(0)
sys.exit(1)
" "$issue_num" 2>/dev/null || return 1
}

# _scan_dev_issue_stage — dev_issue with concurrent slot limiting, priority sort, dep gating.
_scan_dev_issue_stage() {
    local slug="$1" repo="$2" trigger_label="$3" event_type="$4"

    local _inflight _slots
    _inflight=$(count_inflight_prs "$slug" "$repo")
    _slots=$(( MAX_CONCURRENT_PRS - _inflight ))
    log "dev_issue: max=${MAX_CONCURRENT_PRS} in-flight=${_inflight} slots=${_slots}"

    if [ "$_slots" -le 0 ]; then
        log "skip dev_issue for $slug: ${_inflight}/${MAX_CONCURRENT_PRS} pipeline PRs in flight"
        return
    fi

    local _rows_tmp _seen_tmp
    _rows_tmp=$(mktemp)
    _seen_tmp=$(mktemp)

    # Collect and deduplicate issues from the workflow's dev trigger label.
    while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        local _n
        _n=$(printf '%s' "$_r" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        if ! grep -qxF "$_n" "$_seen_tmp" 2>/dev/null; then
            printf '%s\n' "$_n" >> "$_seen_tmp"
            printf '%s\n' "$_r" >> "$_rows_tmp"
        fi
    done < <(backend_list_issues_with_label "$repo" "$trigger_label")

    # Sort by (priority-label, number) so high-priority issues fire first.
    local _sorted_tmp
    _sorted_tmp=$(mktemp)
    _sort_rows_by_priority < "$_rows_tmp" > "$_sorted_tmp"
    mv "$_sorted_tmp" "$_rows_tmp"

    local _emitted=0
    while IFS= read -r _row; do
        [ "$_emitted" -ge "$_slots" ] && break
        [ -z "$_row" ] && continue
        local _num _title _url _author _labels _unmet _evt
        _num=$(printf '%s' "$_row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        _title=$(printf '%s' "$_row"  | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        _url=$(printf '%s' "$_row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        _author=$(printf '%s' "$_row" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author',''))")
        _labels=$(printf '%s' "$_row" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('labels') or []))")
        if ! author_is_allowed "$_author" "$_labels"; then
            log "skip dev_issue #$_num: author '$_author' not in ALLOWED_AUTHORS"
            continue
        fi
        if issue_is_claimed "$slug" "$repo" "$_num"; then
            continue
        fi
        # Dependency gate: defer if the issue body declares unmet deps.
        _unmet=$(backend_issue_unmet_deps "$repo" "$_num" 2>/dev/null || true)
        if [ -n "$_unmet" ]; then
            log "defer dev_issue #$_num $_title — unmet deps: $(printf '%s' "$_unmet" | tr '\n' ' ')"
            continue
        fi
        # Duplicate-PR guard: skip if an open PR already closes this issue.
        # On gh error the helper returns empty (fail-open) so we proceed normally.
        local _existing_pr
        _existing_pr=$(_scan_has_open_pr_for_issue "$repo" "$_num" 2>/dev/null || true)
        if [ -n "$_existing_pr" ]; then
            log "skip dev_issue #$_num: open PR #$_existing_pr already closes it"
            continue
        fi
        _evt=$(_emit_issue_event "$event_type" "$slug" "$repo" "$_num" "$_title" "$_url")
        emit "$_evt" "${event_type}:${slug}:${_num}"
        _scanner_jobs_enqueue "$slug" "$event_type" "$_num"
        _emitted=$(( _emitted + 1 ))
    done < "$_rows_tmp"
    rm -f "$_rows_tmp" "$_seen_tmp"
}

# _scan_pr_stage <slug> <repo> <trigger_label> <handler> <event_type>
# Polls for PRs carrying trigger_label and emits the appropriate event.
# A PR is skipped if it has already moved downstream (has a later-stage trigger
# label) or is actively being handled (in-review / deprecated rework-alias operational labels).
_scan_pr_stage() {
    local slug="$1" repo="$2" trigger_label="$3" handler="$4" event_type="$5"

    local downstream
    downstream=$(_pr_downstream_labels "$slug" "$trigger_label")

    # For dev-rework-handler: when the trigger label is NOT the workflow's
    # primary rework trigger (i.e., it comes from a qa-fail stage), add
    # rework_context so the handler knows the origin.
    local rework_context_key="" rework_context_val=""
    if [ "$handler" = "dev-rework-handler" ]; then
        local rework_trigger
        rework_trigger=$(loop_stage_trigger "$slug" "rework" "pr" 2>/dev/null || true)
        if [ -n "$rework_trigger" ] && [ "$trigger_label" != "$rework_trigger" ]; then
            rework_context_key="rework_context"
            rework_context_val="qa-fail"
        fi
    fi

    # Cap new emits per tick, same as _scan_issue_stage but resolved per-stage.
    local _cap; _cap=$(_stage_cap "$event_type")
    local _emitted=0
    log "${event_type}: max=${_cap} (per-tick emit cap)"
    while IFS= read -r row; do
        [ "$_emitted" -ge "$_cap" ] && break
        [ -z "$row" ] && continue
        local num title url labels
        num=$(printf '%s' "$row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        title=$(printf '%s' "$row"  | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        url=$(printf '%s' "$row"    | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        labels=$(printf '%s' "$row" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('labels') or []))")

        # Refuse to dispatch loop-handlers on external PRs unless operator-approved.
        # External PRs carry `external-pr` (set by repo auto-label action); Loop should
        # never auto-review them unless the operator explicitly adds `operator-approved`.
        case " $labels " in
            *" $LOOP_LABEL_EXTERNAL_PR "*)
                case " $labels " in
                    *" operator-approved "*) ;;
                    *)
                        log "skip ${event_type} #${num}: ${LOOP_LABEL_EXTERNAL_PR} without operator-approved"
                        continue
                        ;;
                esac
                ;;
        esac

        # Skip if the PR has moved to a downstream stage or is actively being handled.
        # in-review / deprecated rework-alias are handler-set operational labels (not in workflow YAML).
        # shellcheck disable=SC2086
        if backend_pr_has_any_label "$repo" "$num" \
               in-review "$LOOP_LABEL_DEPRECATED_IN_REWORK" \
               "$LOOP_LABEL_BLOCKED" blocked "$LOOP_LABEL_DONE" 'done' \
               ${downstream}; then
            continue
        fi

        # Skip PRs stuck at this stage longer than LOOP_MAX_AGE_IN_STAGE_SECONDS (default 1h).
        # Prevents a zombie PR from consuming the per-tick cap slot indefinitely and
        # starving all other PRs at this stage. After the cooloff window the tracking
        # entry is deleted and the PR gets one more auto-dispatch attempt; if it stalls
        # again a fresh quarantine begins. Set LOOP_STAGE_AGE_COOLOFF_MULTIPLIER to
        # tune the cooloff (default 6× max_age).
        local _max_stage_age="${LOOP_MAX_AGE_IN_STAGE_SECONDS:-3600}"
        local _cooloff_mult="${LOOP_STAGE_AGE_COOLOFF_MULTIPLIER:-6}"
        local _cooloff=$(( _max_stage_age * _cooloff_mult ))
        if _stage_age_exceeded "${event_type}:${slug}:${num}" "$_max_stage_age" "$_cooloff"; then
            log "skip ${event_type} #${num}: stuck at ${trigger_label} for >${_max_stage_age}s — quarantined for ${_cooloff}s then auto-retry"
            continue
        fi

        local evt
        evt=$(_emit_pr_event "$event_type" "$slug" "$repo" "$num" "$title" "$url" \
              "$rework_context_key" "$rework_context_val")
        emit "$evt" "${event_type}:${slug}:${num}"
        _scanner_jobs_enqueue "$slug" "$event_type" "$num"
        _emitted=$(( _emitted + 1 ))
    done < <(backend_list_prs_with_label "$repo" "$trigger_label" | _sort_rows_by_priority)
}

# _sweep_stale_locks — drop lock files whose recorded PID is no longer alive.
# Called at the start of every scanner tick so handlers that died without
# releasing their lock (SIGKILL, set -e abort before trap registration) don't
# block future dispatches indefinitely.
_sweep_stale_locks() {
    local lock_dir="${LOOP_LOCK_DIR:-/tmp/loop-locks}"
    [ -d "$lock_dir" ] || return 0
    local f pid
    for f in "$lock_dir"/*.lock; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null || true)
        if [ -z "$pid" ]; then
            log "WARN: sweep: empty lock file $f — removing"
            rm -f "$f"
            continue
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            log "WARN: sweep: stale lock $f (PID $pid dead) — removing"
            rm -f "$f"
        fi
    done
}

scan_project() {
    local slug="$1"

    if loop_project_is_paused "$slug"; then
        log "paused: skipping $slug"
        return 0
    fi

    # Daily handler-time budget — if today's spend has met the cap, skip
    # emitting new work entirely. In-flight handlers continue; only new
    # dispatches are paused until the next day rolls over.
    if _budget_exceeded; then
        local spent
        spent=$(cat "$(_budget_counter_path)" 2>/dev/null || echo 0)
        log "BUDGET: ${spent}s/${LOOP_DAILY_HANDLER_BUDGET_SECONDS}s — skip $slug"
        return
    fi

    loop_load_project "$slug" || { log "skip: slug '$slug' unloadable"; return; }
    loop_load_backend
    local repo="$REPO"

    local wf_name
    wf_name=$(loop_workflow_for_project "$slug")
    log "scan: $slug ($repo) workflow=$wf_name"

    # Serial / N-slot gate: when `dev.pipeline_slots` is set in projects.yaml,
    # block fresh claims (the workflow's first issue trigger) once the project
    # has that many tickets in flight already. Downstream stages (review/qa/
    # merge for already-claimed work) continue normally, so in-flight tickets
    # keep flowing to completion.
    local _first_issue_trigger=""
    _first_issue_trigger=$(loop_polled_labels "$slug" issue 2>/dev/null | awk 'NF{print; exit}')
    local _slots_gate_active=false
    if [ -n "${PIPELINE_SLOTS:-}" ] && [ "$PIPELINE_SLOTS" -ge 1 ] 2>/dev/null; then
        local _if_issues _if_prs _if_total
        _if_issues=$(count_inflight_issues "$slug" "$repo" "$_first_issue_trigger")
        _if_prs=$(count_inflight_prs "$slug" "$repo")
        _if_total=$(( _if_issues + _if_prs ))
        log "pipeline_slots=${PIPELINE_SLOTS} in-flight=${_if_total} (issues=${_if_issues} prs=${_if_prs})"
        if [ "$_if_total" -ge "$PIPELINE_SLOTS" ]; then
            _slots_gate_active=true
            log "skip first-stage claims for $slug: ${_if_total}/${PIPELINE_SLOTS} tickets in flight"
        fi
    fi

    # Issue stages — iterated from the project's active workflow.
    while IFS= read -r trigger_label; do
        [ -z "$trigger_label" ] && continue
        local handler event_type
        handler=$(loop_handler_for_label "$slug" "$trigger_label" issue 2>/dev/null || true)
        [ -z "$handler" ] && continue
        if $_slots_gate_active && [ "$trigger_label" = "$_first_issue_trigger" ]; then
            continue
        fi
        event_type=$(_handler_to_event_type "$handler")
        _scan_issue_stage "$slug" "$repo" "$trigger_label" "$handler" "$event_type"
    done < <(loop_polled_labels "$slug" issue)

    # Senior-dev escalation — always polled regardless of workflow definition.
    _scan_issue_stage "$slug" "$repo" "senior-dev" "senior-dev-handler" "loop.senior_dev"

    # PR stages — iterated from the project's active workflow.
    while IFS= read -r trigger_label; do
        [ -z "$trigger_label" ] && continue
        local handler event_type
        handler=$(loop_handler_for_label "$slug" "$trigger_label" pr 2>/dev/null || true)
        [ -z "$handler" ] && continue
        event_type=$(_handler_to_event_type "$handler")
        _scan_pr_stage "$slug" "$repo" "$trigger_label" "$handler" "$event_type"
    done < <(loop_polled_labels "$slug" pr)
}

run_once() {
    # Heartbeat: update mtime so the scanner watchdog can detect a wedged process.
    touch "${LOOP_LOG_DIR}/scanner-heartbeat" 2>/dev/null || true
    log "=== scan tick start ==="
    $DRY_RUN || _sweep_stale_locks
    if [[ "${LOOP_JOBS_ENQUEUE:-1}" == "1" ]] && ! $DRY_RUN; then
        jobs_init_schema 2>/dev/null \
            || log "WARN: jobs schema init failed — jobs DB disabled for this tick"
    fi
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
