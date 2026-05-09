#!/usr/bin/env bash
# status.sh — One-shot runtime health summary for the loop pipeline.
# Usage: scripts/status.sh [--json] [--help]
# Exit codes: 0 = all OK/skip, 2 = any DEGRADED, 1 = any FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

# ─── argument parsing ────────────────────────────────────────────────────────
JSON_MODE=false
for arg in "$@"; do
    case "$arg" in
        --json)  JSON_MODE=true ;;
        --help|-h)
            cat <<'USAGE'
Usage: scripts/status.sh [--json] [--help]

One-shot runtime health summary of the loop pipeline.

Sections: scanner, orchestrator, event-queue, retry-counters,
          active-handlers, recent-failures

Exit codes:
  0 — all checks OK (or skipped)
  2 — any check DEGRADED
  1 — any check FAIL (takes precedence over DEGRADED)

Flags:
  --json   Emit a single JSON object to stdout; no other output.
  --help   Print this message and exit 0.

Note: install.sh status is the install-time variant; this is the runtime one.
USAGE
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# ─── helpers ─────────────────────────────────────────────────────────────────
NOW=$(date +%s)

# _elapsed_str <seconds> → human-readable "4m12s"
_elapsed_str() {
    local secs="$1"
    if [ "$secs" -ge 3600 ]; then
        printf '%dh%02dm' $(( secs / 3600 )) $(( (secs % 3600) / 60 ))
    elif [ "$secs" -ge 60 ]; then
        printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 ))
    else
        printf '%ds' "$secs"
    fi
}

# Each probe returns: name<TAB>status<TAB>detail
# status: ok | degraded | fail | skip

# ─── section probes ──────────────────────────────────────────────────────────

_check_scanner() {
    local log_file="${LOOP_LOG_DIR}/loop-scanner.log"
    local interval_secs
    local raw_interval="${LOOP_SCANNER_INTERVAL:-30m}"
    # Parse interval: accept bare seconds or "<N>m" / "<N>h" suffix
    if [[ "$raw_interval" =~ ^([0-9]+)m$ ]]; then
        interval_secs=$(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$raw_interval" =~ ^([0-9]+)h$ ]]; then
        interval_secs=$(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$raw_interval" =~ ^([0-9]+)$ ]]; then
        interval_secs="${BASH_REMATCH[1]}"
    else
        interval_secs=1800
    fi

    local pid=""
    pid=$(pgrep -f "scanner/scanner.sh" 2>/dev/null | head -1 || true)

    if [ ! -f "$log_file" ]; then
        printf 'scanner\tfail\tlog missing: %s' "$log_file"
        return
    fi

    # Get mtime of log file (macOS/Linux fallback)
    local mtime
    mtime=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo 0)
    local age=$(( NOW - mtime ))
    local age_str
    age_str=$(_elapsed_str "$age")
    local pid_str="no PID"
    [ -n "$pid" ] && pid_str="PID $pid"

    if [ "$age" -le $(( interval_secs * 2 )) ]; then
        printf 'scanner\tok\t(%s, last tick %s ago, interval %s)' "$pid_str" "$age_str" "$raw_interval"
    elif [ "$age" -le $(( interval_secs * 4 )) ]; then
        printf 'scanner\tdegraded\t(%s, last tick %s ago — slow; interval %s)' "$pid_str" "$age_str" "$raw_interval"
    else
        printf 'scanner\tfail\t(%s, last tick %s ago — stale; interval %s)' "$pid_str" "$age_str" "$raw_interval"
    fi
}

_check_orchestrator() {
    if [ -z "${LOOP_ORCHESTRATOR:-}" ]; then
        printf 'orchestrator\tskip\t(LOOP_ORCHESTRATOR not set)'
        return
    fi
    if [ -x "$LOOP_ORCHESTRATOR" ]; then
        printf 'orchestrator\tok\t(%s is executable)' "$LOOP_ORCHESTRATOR"
    else
        printf 'orchestrator\tfail\t(%s set but not executable)' "$LOOP_ORCHESTRATOR"
    fi
}

_check_event_queue() {
    local url="${LOOP_EVENT_QUEUE_URL:-}"
    if [ -z "$url" ]; then
        # fallback: check default address if LOOP_DISPATCH_MODE=event-queue
        if [ "${LOOP_DISPATCH_MODE:-direct}" = "event-queue" ]; then
            url="http://localhost:8765"
        else
            printf 'event-queue\tskip\t(LOOP_EVENT_QUEUE_URL not set)'
            return
        fi
    fi

    local health_url="${url%/}/health"
    local response
    response=$(curl -sf -m 1 "$health_url" 2>/dev/null || true)
    if [ -z "$response" ]; then
        printf 'event-queue\tfail\t(%s unreachable)' "$health_url"
        return
    fi

    # Parse queue depth from JSON ({"queue_depth": N} or {"depth": N})
    local depth
    depth=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('queue_depth', d.get('depth', 0)))
except Exception:
    print(0)
" 2>/dev/null || echo 0)

    if [ "$depth" -gt 100 ] 2>/dev/null; then
        printf 'event-queue\tdegraded\t(%s → 200, queue depth %s — high)' "$health_url" "$depth"
    else
        printf 'event-queue\tok\t(%s → 200, queue depth %s)' "$health_url" "$depth"
    fi
}

_check_retry_counters() {
    local files
    # collect retry counter files
    files=$(ls /tmp/loop-po-retries-* 2>/dev/null || true)
    local max_retries="${MAX_RETRIES:-2}"

    if [ -z "$files" ]; then
        printf 'retry-counters\tok\t(no retry counters in /tmp)'
        return
    fi

    local summary=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local base
        base=$(basename "$f")
        # filename: loop-po-retries-<slug>-<num>
        local rest="${base#loop-po-retries-}"
        # rest = <slug>-<num>
        local num="${rest##*-}"
        local slug="${rest%-*}"
        local count
        count=$(cat "$f" 2>/dev/null || echo 0)
        local note=""
        if [ "$count" -ge "$max_retries" ] 2>/dev/null; then
            note=" — needs-clarification"
        fi
        summary="${summary}  ${slug}#${num} (${count}/${max_retries}${note})\n"
    done <<< "$files"

    printf 'retry-counters\tok\t%s' "$summary"
}

_check_active_handlers() {
    local pids
    pids=$(pgrep -af '(po|dev|qa|review|merge|dev-rework|senior-dev)-handler\.sh' 2>/dev/null || true)
    local self_pid="$$"

    if [ -z "$pids" ]; then
        printf 'active-handlers\tok\t(none)'
        return
    fi

    local summary=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local pid
        pid=$(echo "$line" | awk '{print $1}')
        # skip ourselves
        [ "$pid" = "$self_pid" ] && continue
        local cmd
        cmd=$(echo "$line" | awk '{for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":"\n")}')
        # parse handler type
        local htype=""
        case "$cmd" in
            *po-handler*) htype="PO" ;;
            *dev-rework-handler*) htype="dev-rework" ;;
            *senior-dev-handler*) htype="senior-dev" ;;
            *dev-handler*) htype="dev" ;;
            *review-handler*) htype="review" ;;
            *qa-handler*) htype="qa" ;;
            *merge-handler*) htype="merge" ;;
            *) htype="handler" ;;
        esac
        # get process start time
        local lstart=""
        lstart=$(ps -o lstart= -p "$pid" 2>/dev/null || true)
        local age_str=""
        if [ -n "$lstart" ]; then
            local start_epoch
            start_epoch=$(date -d "$lstart" +%s 2>/dev/null || date -j -f "%a %b %d %T %Y" "$lstart" +%s 2>/dev/null || echo 0)
            if [ "$start_epoch" -gt 0 ] 2>/dev/null; then
                local age=$(( NOW - start_epoch ))
                age_str=$(_elapsed_str "$age")
            fi
        fi
        if [ -n "$age_str" ]; then
            summary="${summary}  ${htype} PID ${pid} (started ${age_str} ago)\n"
        else
            summary="${summary}  ${htype} PID ${pid}\n"
        fi
    done <<< "$pids"

    if [ -z "$summary" ]; then
        printf 'active-handlers\tok\t(none — only this process)'
    else
        printf 'active-handlers\tok\t%s' "$summary"
    fi
}

_check_recent_failures() {
    local log_file="${LOOP_LOG_DIR}/loop-po-handler.log"
    if [ ! -f "$log_file" ]; then
        printf 'recent-failures\tok\t(log not found)'
        return
    fi

    local cutoff=$(( NOW - 86400 ))
    # tail to limit input, then grep for failed lines
    local matches
    matches=$(tail -n 5000 "$log_file" 2>/dev/null | grep -i ' failed ' 2>/dev/null || true)

    if [ -z "$matches" ]; then
        printf 'recent-failures\tok\t(none in last 24h)'
        return
    fi

    # Filter to last 24h and cap at 10 entries
    local recent=""
    local count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Try to extract timestamp from line (format: [YYYY-MM-DD HH:MM:SS])
        local ts_str=""
        ts_str=$(echo "$line" | grep -oE '\[?[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}(:[0-9]{2})?\]?' | head -1 | tr -d '[]' || true)
        if [ -n "$ts_str" ]; then
            local ts_epoch
            ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ts_str" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$ts_str" +%s 2>/dev/null || echo 0)
            if [ "$ts_epoch" -gt 0 ] && [ "$ts_epoch" -lt "$cutoff" ] 2>/dev/null; then
                continue
            fi
        fi
        recent="${recent}  ${line}\n"
        count=$(( count + 1 ))
        [ "$count" -ge 10 ] && break
    done <<< "$matches"

    if [ -z "$recent" ]; then
        printf 'recent-failures\tok\t(none in last 24h)'
    else
        printf 'recent-failures\tok\t%s entries\n%s' "$count" "$recent"
    fi
}

# ─── collect probes ──────────────────────────────────────────────────────────

RECORDS=()
RECORDS+=("$(_check_scanner)")
RECORDS+=("$(_check_orchestrator)")
RECORDS+=("$(_check_event_queue)")
RECORDS+=("$(_check_retry_counters)")
RECORDS+=("$(_check_active_handlers)")
RECORDS+=("$(_check_recent_failures)")

# ─── compute aggregate exit code ─────────────────────────────────────────────
# 0=ok, 2=degraded, 1=fail (fail wins over degraded wins over ok)
AGG_STATUS="ok"
for rec in "${RECORDS[@]}"; do
    status=$(echo "$rec" | cut -f2)
    case "$status" in
        fail)     AGG_STATUS="fail" ;;
        degraded) [ "$AGG_STATUS" != "fail" ] && AGG_STATUS="degraded" ;;
    esac
done

# ─── output ──────────────────────────────────────────────────────────────────
if [ "$JSON_MODE" = true ]; then
    # Build JSON via python heredoc — do not shell-construct JSON
    python3 - "${RECORDS[@]}" <<'PY'
import json, sys

args = sys.argv[1:]
checks = {}
retry_counters = []
active_handlers = []
recent_failures = []
agg = "ok"

for rec in args:
    parts = rec.split('\t', 2)
    if len(parts) < 3:
        parts += [''] * (3 - len(parts))
    name, status, detail = parts[0], parts[1], parts[2]
    checks[name] = {"status": status, "detail": detail}
    if status == "fail" and agg != "fail":
        agg = "fail"
    elif status == "degraded" and agg == "ok":
        agg = "degraded"

# retry-counters and active-handlers go in their own lists
if "retry-counters" in checks:
    detail = checks["retry-counters"]["detail"]
    for line in detail.splitlines():
        line = line.strip()
        if line:
            retry_counters.append(line)

if "active-handlers" in checks:
    detail = checks["active-handlers"]["detail"]
    for line in detail.splitlines():
        line = line.strip()
        if line and line != "none":
            active_handlers.append(line)

if "recent-failures" in checks:
    detail = checks["recent-failures"]["detail"]
    for line in detail.splitlines():
        line = line.strip()
        if line and not line.startswith(("none", "log not")):
            recent_failures.append(line)

out = {
    "status": agg,
    "checks": checks,
    "retry_counters": retry_counters,
    "active_handlers": active_handlers,
    "recent_failures": recent_failures,
}
print(json.dumps(out))
PY
    exit_code=0
    case "$AGG_STATUS" in
        fail)     exit_code=1 ;;
        degraded) exit_code=2 ;;
        *)        exit_code=0 ;;
    esac
    exit "$exit_code"
fi

# ─── plain-text output ───────────────────────────────────────────────────────
printf 'loop status — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

for rec in "${RECORDS[@]}"; do
    name=$(echo "$rec" | cut -f1)
    status=$(echo "$rec" | cut -f2)
    detail=$(echo "$rec" | cut -f3-)

    status_label=""
    case "$status" in
        ok)       status_label="OK      " ;;
        degraded) status_label="DEGRADED" ;;
        fail)     status_label="FAIL    " ;;
        skip)     status_label="--      " ;;
        *)        status_label="$status  " ;;
    esac

    case "$name" in
        retry-counters|active-handlers|recent-failures)
            printf '%-20s %s\n' "$name" "$status_label"
            # print detail lines indented
            while IFS= read -r dline; do
                [ -n "$dline" ] && printf '  %s\n' "$dline"
            done <<< "$detail"
            ;;
        *)
            printf '%-20s %s %s\n' "$name" "$status_label" "$detail"
            ;;
    esac
done

printf '\n'

case "$AGG_STATUS" in
    fail)     exit 1 ;;
    degraded) exit 2 ;;
    *)        exit 0 ;;
esac
