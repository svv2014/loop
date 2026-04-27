#!/usr/bin/env bash
# lib/bounty.sh — fire-and-forget helper to report pipeline events to loop-monitor.
# Source this file to get bounty_report(). All calls are best-effort (|| true).
#
# Payload conforms to bounty event API v1.0 (see svv2014/loop issue #4 spec):
#   { api, core_version, event, role, agent, model, project,
#     issue_num, pr_num, detail, timestamp }

BOUNTY_URL="${BOUNTY_URL:-http://127.0.0.1:18792}"
BOUNTY_TIMEOUT="${BOUNTY_TIMEOUT:-3}"
BOUNTY_API_VERSION="1.0"

# bounty_report <event> [key=value ...]
# Keys: agent model role project issue_num pr_num detail
# Example: bounty_report "dev_start" role=dev model=sonnet project=myapp issue_num=42
bounty_report() {
    local event="${1:-unknown}"
    shift || true

    local agent="" model="" role="" project="" issue_num="" pr_num="" detail=""
    for kv in "$@"; do
        case "$kv" in
            agent=*)     agent="${kv#agent=}" ;;
            model=*)     model="${kv#model=}" ;;
            role=*)      role="${kv#role=}" ;;
            project=*)   project="${kv#project=}" ;;
            issue_num=*) issue_num="${kv#issue_num=}" ;;
            pr_num=*)    pr_num="${kv#pr_num=}" ;;
            detail=*)    detail="${kv#detail=}" ;;
        esac
    done

    local payload
    payload=$(
        _API="$BOUNTY_API_VERSION" _CV="${LOOP_VERSION:-unknown}" \
        _BE="$event" _BA="$agent" _BM="$model" _BR="$role" \
        _BP="$project" _BD="$detail" _BI="$issue_num" _BPN="$pr_num" \
        python3 - <<'PY'
import json, os, datetime
d = {
    "api":          os.environ.get("_API", "1.0"),
    "core_version": os.environ.get("_CV") or "unknown",
    "event":        os.environ.get("_BE", "unknown"),
    "agent":        os.environ.get("_BA") or None,
    "model":        os.environ.get("_BM") or None,
    "role":         os.environ.get("_BR") or None,
    "project":      os.environ.get("_BP") or None,
    "detail":       os.environ.get("_BD") or None,
    "timestamp":    datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
for k, env in [("issue_num", "_BI"), ("pr_num", "_BPN")]:
    v = os.environ.get(env, "")
    if v and v.strip().isdigit():
        d[k] = int(v.strip())
print(json.dumps(d))
PY
    ) 2>/dev/null || true

    [ -z "$payload" ] && return 0

    curl -sf \
        --max-time "$BOUNTY_TIMEOUT" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${BOUNTY_URL}/api/report" \
        >/dev/null 2>&1 || true
}
