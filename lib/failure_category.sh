#!/usr/bin/env bash
# lib/failure_category.sh — classify *_failed events with a structured category.
#
# Usage:
#   source "$LOOP_ROOT/lib/failure_category.sh"
#   category=$(loop_failure_category "$stderr_text" "$exit_code")
#
# Prints exactly one of: budget, network, git_conflict, model_error, tool_error, unknown.
# Classification rules are evaluated top-to-bottom; first match wins.

# loop_failure_category <stderr_text> [exit_code]
loop_failure_category() {
    local text="$1"
    local rc="${2:-1}"
    LOOP_FC_TEXT="$text" LOOP_FC_RC="$rc" python3 - <<'PY'
import os, re, sys

text = os.environ.get('LOOP_FC_TEXT', '')
rc   = int(os.environ.get('LOOP_FC_RC', '1') or '1')

if re.search(r'daily\.budget|budget cap|budget exhausted|LOOP_DAILY_BUDGET', text):
    print('budget'); sys.exit(0)

if re.search(r'5\d\d|timeout|timed out|Connection(?:Refused|Reset|Error)|TimeoutError|429|rate limit', text):
    print('network'); sys.exit(0)

if re.search(r'CONFLICT \(|Merge conflict|rebase.*conflict|<<<<<<< HEAD', text):
    print('git_conflict'); sys.exit(0)

if re.search(r'claude .*(API error|invalid_request|overloaded|model_error)|anthropic.*error|prompt is too long', text, re.IGNORECASE):
    print('model_error'); sys.exit(0)

if re.search(r'gh: |git: |jq: |command not found', text) or rc != 0:
    print('tool_error'); sys.exit(0)

print('unknown')
PY
}
