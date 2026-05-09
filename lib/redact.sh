#!/usr/bin/env bash
# lib/redact.sh — loop_redact_secrets: scrub credentials from text before posting.
# Sourced by po-handler.sh. Safe to source multiple times.
# Returns 1 (and prints nothing) when input is empty — callers should fail-closed.

loop_redact_secrets() {
    local text="$1"
    [ -z "$text" ] && return 1
    printf '%s' "$text" \
      | sed -E 's/(ANTHROPIC_API_KEY|GH_TOKEN|GITHUB_TOKEN|OPENAI_API_KEY)=[^[:space:]'"'"'"]*/\1=[REDACTED]/g' \
      | sed -E 's/Bearer [A-Za-z0-9._~+/=-]+/Bearer [REDACTED]/g' \
      | sed -E 's/ghp_[A-Za-z0-9]+/[REDACTED-GH-PAT]/g' \
      | sed -E 's/sk-[A-Za-z0-9_-]+/[REDACTED-OPENAI]/g' \
      | sed -E "s|${HOME}|~|g; s|/Users/[^/[:space:]]+|~|g"
}
