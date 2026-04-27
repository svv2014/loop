#!/usr/bin/env bash
# lib/runner.sh — Run an AI coding agent with a prompt in a working directory.
#
# Supports multiple backends. Set LOOP_AGENT in loop.env:
#   "claude"   — Claude Code CLI (default)
#   "codex"    — OpenAI Codex CLI
#   "gemini"   — Google Gemini CLI
#   "aider"    — Aider
#   "custom"   — Custom script (set LOOP_AGENT_CMD)
#
# Usage (from other scripts):
#   source "$LOOP_ROOT/lib/runner.sh"
#   loop_run_agent "$prompt" "$working_dir"

# Requires lib/env.sh to be sourced first (for LOOP_AGENT, LOOP_AGENT_CMD, etc.)

LOOP_AGENT="${LOOP_AGENT:-claude}"

loop_run_agent() {
    local prompt="$1"
    local cwd="${2:-$(pwd)}"

    # If a full orchestrator is configured, use it (backward compat)
    if [ -n "${LOOP_ORCHESTRATOR:-}" ] && [ -x "${LOOP_ORCHESTRATOR}" ]; then
        "$LOOP_ORCHESTRATOR" "$prompt" --cwd "$cwd"
        return $?
    fi

    case "$LOOP_AGENT" in
        claude)
            claude -p \
                --model "${LOOP_AGENT_MODEL:-sonnet}" \
                --output-format text \
                --dangerously-skip-permissions \
                "$prompt"
            ;;
        codex)
            codex \
                --model "${LOOP_AGENT_MODEL:-o4-mini}" \
                --approval-mode full-auto \
                -q "$prompt"
            ;;
        gemini)
            gemini \
                -m "${LOOP_AGENT_MODEL:-gemini-2.5-pro}" \
                --sandbox \
                -p "$prompt"
            ;;
        aider)
            aider \
                --model "${LOOP_AGENT_MODEL:-sonnet}" \
                --yes-always \
                --message "$prompt"
            ;;
        custom)
            if [ -z "${LOOP_AGENT_CMD:-}" ]; then
                echo "ERROR: LOOP_AGENT=custom but LOOP_AGENT_CMD not set" >&2
                return 2
            fi
            eval "$LOOP_AGENT_CMD" "$prompt"
            ;;
        *)
            echo "ERROR: Unknown LOOP_AGENT='$LOOP_AGENT'. Use: claude, codex, gemini, aider, custom" >&2
            return 2
            ;;
    esac
}
