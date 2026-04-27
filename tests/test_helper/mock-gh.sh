#!/usr/bin/env bash
# Mock gh binary for bats tests.
# GH_MOCK_OUTPUT — written to stdout (default: empty)
# GH_MOCK_EXIT   — exit code (default: 0)
# GH_MOCK_LOG    — if set, each invocation appended as "gh <args>" to this file
[ -n "${GH_MOCK_LOG:-}" ] && printf 'gh %s\n' "$*" >> "$GH_MOCK_LOG"
[ -n "${GH_MOCK_OUTPUT:-}" ] && printf '%s\n' "$GH_MOCK_OUTPUT"
exit "${GH_MOCK_EXIT:-0}"
