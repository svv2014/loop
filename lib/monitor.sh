#!/usr/bin/env bash
# lib/monitor.sh — shared event-emission helper for loop-monitor.
# Sourced by lib/progress.sh (and any future monitor emitters in handlers).
# Does NOT source env.sh — callers are responsible for setting LOOP_MONITOR_URL.

# Usage: _loop_emit_event <event_type> <json_payload_string>
_loop_emit_event() {
    local event_type="$1" payload="$2"
    local monitor_url="${LOOP_MONITOR_URL:-}"
    [ -n "$monitor_url" ] || return 0
    local body
    body=$(python3 -c "
import json, sys
try:
    p = json.loads(sys.argv[1])
    print(json.dumps({'type': sys.argv[2], 'payload': p}))
except Exception:
    pass" "$payload" "$event_type" 2>/dev/null || echo "")
    [ -n "$body" ] || return 0
    curl -s -X POST "$monitor_url/events" \
        -H 'Content-Type: application/json' \
        -d "$body" >/dev/null 2>&1 || true
}
