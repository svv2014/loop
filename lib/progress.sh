#!/usr/bin/env bash
# lib/progress.sh — background progress-event poller for handler runs.
#
# Usage:
#   source lib/progress.sh
#   progress_start <event_prefix>   # spawns background poller
#   progress_stop                   # kills the poller cleanly
#
# The poller emits <event_prefix>_progress events to LOOP_MONITOR_URL every
# LOOP_PROGRESS_INTERVAL_SEC (default: 30) seconds while a handler is running.
#
# Context is read from environment variables at emission time:
#   SLUG, ISSUE_NUM, PR_NUM — set by the calling handler
# shellcheck source=./monitor.sh
source "${LOOP_ROOT:?}/lib/monitor.sh"

_LOOP_PROGRESS_PID=""

# _progress_detect_detail <project> <handler_pid>
# Finds the most-recently-modified transcript file under LOOP_TRANSCRIPT_DIR
# matching the pid or project, extracts the latest tool_use name + input
# summary from the trailing JSONL lines. Falls back to "working" on any error.
# Wrapped in a 2-second timeout — never blocks the caller.
_progress_detect_detail() {
    local project="${1:-}" handler_pid="${2:-}"
    local transcript_dir="${LOOP_TRANSCRIPT_DIR:-/tmp/orchestrator-transcripts}"

    [ -d "$transcript_dir" ] || { printf '%s' "working"; return 0; }

    local tf=""
    # Find candidate files by pid or project name, pick most-recently-modified
    local candidates
    candidates=$(find "$transcript_dir" -maxdepth 2 -type f \
        \( -name "*${handler_pid}*" -o -name "*${project}*" \) \
        2>/dev/null || true)
    if [ -n "$candidates" ]; then
        tf=$(echo "$candidates" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -1 || true)
    fi
    # Fallback: newest file in transcript dir
    if [ -z "$tf" ]; then
        local newest
        newest=$(ls -t "$transcript_dir"/ 2>/dev/null | head -1 || true)
        [ -n "$newest" ] && tf="$transcript_dir/$newest"
    fi

    [ -n "$tf" ] && [ -f "$tf" ] || { printf '%s' "working"; return 0; }

    local detail
    detail=$(TRANSCRIPT_FILE="$tf" timeout 2 python3 <<'PY' 2>/dev/null
import sys, json, os
tf = os.environ.get('TRANSCRIPT_FILE', '')
detail = ''
try:
    with open(tf) as fh:
        lines = fh.readlines()[-50:]
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get('type') == 'tool_use':
                name = obj.get('name', '')
                inp = obj.get('input', {})
                if isinstance(inp, dict):
                    first_val = next(iter(inp.values()), '') if inp else ''
                    inp_str = str(first_val)[:60] if first_val else ''
                else:
                    inp_str = str(inp)[:60]
                if name:
                    detail = name + (': ' + inp_str if inp_str else '')
        except Exception:
            continue
except Exception:
    pass
print(detail if detail else 'working')
PY
    ) || detail=""

    detail="${detail:-working}"
    printf '%s' "${detail:0:120}"
}

# _progress_emit <event_prefix>
# Builds and POSTs one <prefix>_progress event to LOOP_MONITOR_URL.
_progress_emit() {
    local prefix="$1"
    local monitor_url="${LOOP_MONITOR_URL:-}"
    [ -n "$monitor_url" ] || return 0

    local detail
    detail=$(_progress_detect_detail "${SLUG:-}" "$$")

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

    local payload_json
    payload_json=$(python3 -c "
import json, os, sys
proj  = os.environ.get('SLUG', '')
issue = os.environ.get('ISSUE_NUM', '')
pr    = os.environ.get('PR_NUM', '')
pid   = os.getpid()
detail = sys.argv[1][:120]
ts   = sys.argv[2]
p = {'project': proj, 'pid': pid, 'detail': detail, 'ts': ts}
if issue:
    try:
        p['issue_num'] = int(issue)
    except ValueError:
        p['issue_num'] = issue
elif pr:
    try:
        p['pr_num'] = int(pr)
    except ValueError:
        p['pr_num'] = pr
print(json.dumps(p))
" "$detail" "$ts" 2>/dev/null) || return 0

    [ -n "$payload_json" ] || return 0
    _loop_emit_event "${prefix}_progress" "$payload_json" || true
}

# progress_start <event_prefix>
# Spawns a background poller that emits <prefix>_progress events periodically.
# Stores the poller PID in _LOOP_PROGRESS_PID for progress_stop.
progress_start() {
    local prefix="$1"
    local interval="${LOOP_PROGRESS_INTERVAL_SEC:-30}"
    (
        _poller_sleep_pid=""
        trap '[ -n "$_poller_sleep_pid" ] && kill "$_poller_sleep_pid" 2>/dev/null || true; exit 0' TERM INT
        while true; do
            sleep "$interval" &
            _poller_sleep_pid=$!
            wait "$_poller_sleep_pid" 2>/dev/null || true
            _poller_sleep_pid=""
            _progress_emit "$prefix"
        done
    ) &
    _LOOP_PROGRESS_PID=$!
}

# progress_stop
# Signals the poller to stop (TERM, then KILL after 1 s) and waits for it.
# Safe to call multiple times or when no poller is running.
progress_stop() {
    [ -n "${_LOOP_PROGRESS_PID:-}" ] || return 0
    local pid="$_LOOP_PROGRESS_PID"
    _LOOP_PROGRESS_PID=""
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}
