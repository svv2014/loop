#!/usr/bin/env bash
# Mock curl binary for bats tests.
# CURL_MOCK_EXIT        — exit code (default: 0)
# CURL_MOCK_LOG         — if set, each invocation appended as "curl <args>" to this file
# CURL_PAYLOAD_FILE     — if set, the -d payload body is written to this file
[ -n "${CURL_MOCK_LOG:-}" ] && printf 'curl %s\n' "$*" >> "$CURL_MOCK_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-d" ] && [ "$#" -gt 1 ]; then
        [ -n "${CURL_PAYLOAD_FILE:-}" ] && printf '%s' "$2" > "$CURL_PAYLOAD_FILE"
        shift 2
    else
        shift
    fi
done
exit "${CURL_MOCK_EXIT:-0}"
