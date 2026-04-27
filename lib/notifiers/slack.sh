#!/usr/bin/env bash
# lib/notifiers/slack.sh — Post a notification to a Slack webhook.
# Requires: curl
# Usage: LOOP_NOTIFY="lib/notifiers/slack.sh"
#   Set SLACK_WEBHOOK_URL to your Slack incoming-webhook URL.

set -euo pipefail

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    echo "slack.sh: SLACK_WEBHOOK_URL is not set" >&2
    exit 1
fi

message="$1"

curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"text\": $(printf '%s' "$message" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
