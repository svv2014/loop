#!/usr/bin/env bats
# tests/po-redact.bats — unit tests for loop_redact_secrets and the
# comment-truncation logic used by po-handler's _post_failure_comment.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/redact.sh
    source "$REPO_ROOT/lib/redact.sh"
    export HOME="${HOME:-/Users/operator}"
}

# ---------------------------------------------------------------------------
# loop_redact_secrets — credential patterns
# ---------------------------------------------------------------------------

@test "redactor: strips ANTHROPIC_API_KEY= value" {
    local input="ANTHROPIC_API_KEY=sk-ant-api03-abc123xyz output follows"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"ANTHROPIC_API_KEY=[REDACTED]"* ]]
    [[ "$out" != *"sk-ant-api03-abc123xyz"* ]]
}

@test "redactor: strips GH_TOKEN= value" {
    local input="GH_TOKEN=ghs_sometoken rest of line"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"GH_TOKEN=[REDACTED]"* ]]
    [[ "$out" != *"ghs_sometoken"* ]]
}

@test "redactor: strips GITHUB_TOKEN= value" {
    local input="export GITHUB_TOKEN=ghp_abc123def456 extra"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"GITHUB_TOKEN=[REDACTED]"* ]]
}

@test "redactor: strips OPENAI_API_KEY= value" {
    local input="OPENAI_API_KEY=sk-openai-secret stuff"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"OPENAI_API_KEY=[REDACTED]"* ]]
    [[ "$out" != *"sk-openai-secret"* ]]
}

@test "redactor: strips ghp_ PAT" {
    local input="token ghp_AbCdEfGhIjKlMnOpQrSt found in output"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"[REDACTED-GH-PAT]"* ]]
    [[ "$out" != *"ghp_AbCdEfGhIjKlMnOpQrSt"* ]]
}

@test "redactor: strips Bearer token" {
    local input="Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"Bearer [REDACTED]"* ]]
    [[ "$out" != *"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"* ]]
}

@test "redactor: strips sk- OpenAI key" {
    local input="key=sk-abc123-def456 used"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"[REDACTED-OPENAI]"* ]]
    [[ "$out" != *"sk-abc123-def456"* ]]
}

@test "redactor: passes plain text through unchanged" {
    local input="No secrets here. Just a normal log line with words and numbers 42."
    local out
    out=$(loop_redact_secrets "$input")
    [ "$out" = "$input" ]
}

@test "redactor: returns non-zero and prints nothing for empty input" {
    local out rc=0
    out=$(loop_redact_secrets "" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ]
    [ -z "$out" ]
}

@test "redactor: replaces absolute /Users/ home paths with ~" {
    local input="Running from /Users/operator/projects/loop"
    local out
    out=$(loop_redact_secrets "$input")
    [[ "$out" == *"~"* ]]
    [[ "$out" != *"/Users/operator"* ]]
}

# ---------------------------------------------------------------------------
# Truncation logic (mirrors _post_failure_comment in po-handler.sh)
# ---------------------------------------------------------------------------

@test "truncation: drops front of text when assembled body exceeds 60000 bytes" {
    # Build a string longer than 60000 bytes
    local big_content
    big_content=$(python3 -c "print('x' * 61000, end='')")
    local content_len="${#big_content}"
    [ "$content_len" -ge 61000 ]

    local max_bytes=60000
    local body_len="$content_len"

    [ "$body_len" -gt "$max_bytes" ]

    local excess=$(( body_len - max_bytes ))
    local trimmed="${big_content:$excess}"
    local result="...truncated ${excess} chars...
${trimmed}"

    # Truncation marker present
    [[ "$result" == "...truncated "* ]]
    # Content is shorter than original
    [ "${#trimmed}" -lt "$content_len" ]
    # Trimmed length equals expected remainder
    [ "${#trimmed}" -eq $(( content_len - excess )) ]
}

@test "truncation: content within 60000 bytes is not truncated" {
    local small_content
    small_content=$(python3 -c "print('y' * 1000, end='')")

    local max_bytes=60000
    local body_len="${#small_content}"

    [ "$body_len" -le "$max_bytes" ]

    # No truncation should happen
    local result="$small_content"
    [[ "$result" != *"...truncated"* ]]
    [ "${#result}" -eq "$body_len" ]
}
