#!/usr/bin/env bash
# lib/failure_category.sh — classify handler stderr into structured failure categories.
#
# Usage:
#   source "$LOOP_ROOT/lib/failure_category.sh"
#   category=$(loop_failure_category "$stderr_text" [exit_code])
#
# Returns exactly one of:
#   budget | network | git_conflict | model_error | tool_error | unknown
#
# Rules are evaluated top-to-bottom; first match wins.

# loop_failure_category <stderr_text> [exit_code]
# Prints a single category token to stdout.
loop_failure_category() {
    local text="${1:-}"
    local rc="${2:-1}"

    # budget — daily budget cap exhausted
    if printf '%s' "$text" | grep -qE '(daily.budget|budget cap|budget exhausted|LOOP_DAILY_BUDGET)'; then
        printf 'budget'
        return
    fi

    # network — HTTP 5xx, connection errors, timeouts, rate limits
    if printf '%s' "$text" | grep -qE '(HTTP 5[0-9][0-9]|timeout|timed out|Connection(Refused|Reset|Error)|TimeoutError|429|rate limit)'; then
        printf 'network'
        return
    fi

    # git_conflict — merge or rebase conflict markers
    if printf '%s' "$text" | grep -qE '(CONFLICT \(|Merge conflict|rebase.*conflict|<<<<<<< HEAD)'; then
        printf 'git_conflict'
        return
    fi

    # model_error — Claude/Anthropic API errors, overloaded, prompt too long
    if printf '%s' "$text" | grep -qiE '(claude.*(API error|invalid_request|overloaded|model_error)|anthropic.*error|prompt is too long)'; then
        printf 'model_error'
        return
    fi

    # tool_error — gh/git/jq CLI errors, command not found, or any non-zero exit
    if printf '%s' "$text" | grep -qE '(gh: |git: |jq: |command not found)' \
        || [ "${rc}" -ne 0 ]; then
        printf 'tool_error'
        return
    fi

    printf 'unknown'
}
