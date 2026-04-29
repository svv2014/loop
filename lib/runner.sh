#!/usr/bin/env bash
# lib/runner.sh — Run an AI coding agent with a prompt in a working directory.
#
# Supports multiple backends. Set LOOP_AGENT in loop.env:
#   "claude"   — Claude Code CLI (default)
#   "codex"    — OpenAI Codex CLI
#   "gemini"   — Google Gemini CLI
#   "aider"    — Aider
#   "custom"   — Custom script (set LOOP_AGENT_CMD or per-project cmd:)
#
# Per-project overrides (set by loop_load_project via lib/config.sh):
#   _PROJECT_AGENT    — overrides LOOP_AGENT for this project
#   _PROJECT_MODEL    — overrides LOOP_AGENT_MODEL for this project
#   _PROJECT_FALLBACK — newline-delimited "agent|model|cmd" fallback entries
#
# Fallback chain: on recoverable failure (auth error, rate limit, 5xx, network)
# loop_run_agent walks the fallback list before surfacing the error.
# Recoverable signals: 401, 403+auth, 429, 5xx, "rate limit", "timeout",
#   "connection refused", "econnreset", "service unavailable".
#
# Usage (from other scripts):
#   source "$LOOP_ROOT/lib/runner.sh"
#   loop_run_agent "$prompt" "$working_dir"

# Requires lib/env.sh to be sourced first (for LOOP_AGENT, LOOP_AGENT_CMD, etc.)

LOOP_AGENT="${LOOP_AGENT:-claude}"

# _loop_invoke_agent <agent> <model> <cmd> <prompt> <cwd>
# Invokes a single agent attempt. Writes stderr to a temp file so the caller
# can inspect it for recoverable-signal patterns.
# Returns the agent's exit code.
_loop_invoke_agent() {
    local agent="$1"
    local model="$2"
    local cmd="$3"
    local prompt="$4"
    local cwd="$5"

    case "$agent" in
        claude)
            claude -p \
                --model "${model:-sonnet}" \
                --output-format text \
                --dangerously-skip-permissions \
                --cwd "$cwd" \
                "$prompt"
            ;;
        codex)
            (cd "$cwd" && codex \
                --model "${model:-o4-mini}" \
                --approval-mode full-auto \
                -q "$prompt")
            ;;
        gemini)
            (cd "$cwd" && gemini \
                -m "${model:-gemini-2.5-pro}" \
                --sandbox \
                -p "$prompt")
            ;;
        aider)
            (cd "$cwd" && aider \
                --model "${model:-sonnet}" \
                --yes-always \
                --message "$prompt")
            ;;
        custom)
            if [ -z "${cmd:-}" ] && [ -z "${LOOP_AGENT_CMD:-}" ]; then
                echo "ERROR: agent=custom but neither cmd nor LOOP_AGENT_CMD is set" >&2
                return 2
            fi
            local _cmd="${cmd:-$LOOP_AGENT_CMD}"
            eval "$_cmd" "$prompt"
            ;;
        *)
            echo "ERROR: Unknown agent='$agent'. Use: claude, codex, gemini, aider, custom" >&2
            return 2
            ;;
    esac
}

# _loop_is_recoverable <stderr_text>
# Returns 0 if the text contains a recoverable-signal pattern.
_loop_is_recoverable() {
    local text="$1"
    echo "$text" | grep -qiE \
        '(\b401\b|403[^0-9]*auth|auth[^0-9]*403|\b429\b|[^0-9]5[0-9]{2}[^0-9]|rate limit|timeout|connection refused|econnreset|service unavailable)'
}

# loop_run_agent <prompt> [cwd]
# Runs the agent with per-project overrides and walks the fallback chain on
# recoverable errors.
loop_run_agent() {
    local prompt="$1"
    local cwd="${2:-$(pwd)}"

    # Full orchestrator overrides everything (backward compat)
    if [ -n "${LOOP_ORCHESTRATOR:-}" ] && [ -x "${LOOP_ORCHESTRATOR}" ]; then
        "$LOOP_ORCHESTRATOR" "$prompt" --mode quick --cwd "$cwd"
        return $?
    fi

    # Resolve effective agent/model from per-project override or global default
    local eff_agent="${_PROJECT_AGENT:-${LOOP_AGENT:-claude}}"
    local eff_model="${_PROJECT_MODEL:-${LOOP_AGENT_MODEL:-}}"
    local eff_cmd=""

    # Build fallback list: each entry is "agent|model|cmd"
    # _PROJECT_FALLBACK is newline-delimited; empty means no fallbacks.
    local fallback_list="${_PROJECT_FALLBACK:-}"

    local attempt=0
    local stderr_file
    stderr_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$stderr_file'" RETURN

    local cur_agent="$eff_agent"
    local cur_model="$eff_model"
    local cur_cmd="$eff_cmd"
    local attempt_log=""

    while true; do
        attempt=$(( attempt + 1 ))
        local label
        if [ "$attempt" -eq 1 ]; then
            label="primary"
        else
            label="fallback $((attempt - 1))"
        fi

        echo "loop_run_agent: attempt $attempt ($label): agent=${cur_agent} model=${cur_model:-<default>}" >&2

        # Run agent; capture stderr separately while still streaming stdout
        _loop_invoke_agent "$cur_agent" "$cur_model" "$cur_cmd" "$prompt" "$cwd" \
            2> >(tee "$stderr_file" >&2)
        local rc=$?

        if [ $rc -eq 0 ]; then
            echo "loop_run_agent: attempt $attempt ($label): ok" >&2
            rm -f "$stderr_file"
            trap - RETURN
            return 0
        fi

        local stderr_tail
        stderr_tail="$(tail -n 20 "$stderr_file" 2>/dev/null || true)"
        attempt_log="${attempt_log}  attempt $attempt ($label) agent=${cur_agent} model=${cur_model:-<default>} exit=${rc}"$'\n'

        if ! _loop_is_recoverable "$stderr_tail"; then
            echo "loop_run_agent: attempt $attempt ($label): unrecoverable error (exit $rc), aborting chain" >&2
            echo "loop_run_agent: summary of attempts:"$'\n'"${attempt_log}" >&2
            rm -f "$stderr_file"
            trap - RETURN
            return $rc
        fi

        echo "loop_run_agent: attempt $attempt ($label): recoverable error (exit $rc), checking for next fallback" >&2

        # Advance to next fallback entry
        if [ -z "$fallback_list" ]; then
            echo "loop_run_agent: no more fallbacks, chain exhausted" >&2
            echo "loop_run_agent: summary of attempts:"$'\n'"${attempt_log}" >&2
            rm -f "$stderr_file"
            trap - RETURN
            return $rc
        fi

        local next_entry
        next_entry="$(echo "$fallback_list" | head -n1)"
        fallback_list="$(echo "$fallback_list" | tail -n +2)"

        local next_agent next_model next_cmd
        next_agent="$(echo "$next_entry" | cut -d'|' -f1)"
        next_model="$(echo "$next_entry" | cut -d'|' -f2)"
        next_cmd="$(echo "$next_entry" | cut -d'|' -f3)"

        # Empty fields mean "use previous / global default"
        [ -n "$next_agent" ] && cur_agent="$next_agent" || cur_agent="${LOOP_AGENT:-claude}"
        cur_model="$next_model"
        cur_cmd="$next_cmd"

        echo "loop_run_agent: trying fallback $((attempt)): agent=${cur_agent} model=${cur_model:-<default>}" >&2
    done
}

# loop_run_senior_agent <prompt> <cwd>
# Like loop_run_agent but uses LOOP_SENIOR_MODEL for the model override.
# Falls back to LOOP_AGENT_MODEL (or per-agent default) when LOOP_SENIOR_MODEL is unset.
loop_run_senior_agent() {
    local prompt="$1"
    local cwd="${2:-$(pwd)}"

    if [ -n "${LOOP_ORCHESTRATOR:-}" ] && [ -x "${LOOP_ORCHESTRATOR}" ]; then
        "$LOOP_ORCHESTRATOR" "$prompt" --mode quick --cwd "$cwd"
        return $?
    fi

    # For the senior agent, override the model with LOOP_SENIOR_MODEL if set.
    # Per-project agent is still honoured; model escalation applies on top.
    local save_project_model="${_PROJECT_MODEL:-}"
    local senior_model="${LOOP_SENIOR_MODEL:-${_PROJECT_MODEL:-${LOOP_AGENT_MODEL:-}}}"
    _PROJECT_MODEL="$senior_model"
    export _PROJECT_MODEL

    loop_run_agent "$prompt" "$cwd"
    local rc=$?

    _PROJECT_MODEL="$save_project_model"
    export _PROJECT_MODEL
    return $rc
}
