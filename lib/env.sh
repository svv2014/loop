#!/usr/bin/env bash
# lib/env.sh — Load loop.env and set up environment.
# Sourced by all scripts. Provides: LOOP_LOG_DIR, LOOP_ORCHESTRATOR, etc.

LOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$(cd "$LOOP_LIB_DIR/.." && pwd)"

# Loop version (single source: VERSION file at repo root)
# shellcheck source=./version.sh
[ -f "$LOOP_LIB_DIR/version.sh" ] && source "$LOOP_LIB_DIR/version.sh"

# Workflow loader — exposes loop_label_for, loop_polled_labels, etc.
# shellcheck source=./workflow.sh
[ -f "$LOOP_LIB_DIR/workflow.sh" ] && source "$LOOP_LIB_DIR/workflow.sh"

# Load user's local env (not committed)
if [ -f "$LOOP_ROOT/loop.env" ]; then
    # shellcheck source=../loop.env
    set -a  # auto-export all vars from loop.env
    source "$LOOP_ROOT/loop.env"
    set +a
fi

# Defaults for anything not set
export LOOP_LOG_DIR="${LOOP_LOG_DIR:-${HOME}/.loop/logs}"
export LOOP_DISPATCH_MODE="${LOOP_DISPATCH_MODE:-direct}"
export LOOP_EVENT_CLIENT="${LOOP_EVENT_CLIENT:-}"
export LOOP_ORCHESTRATOR="${LOOP_ORCHESTRATOR:-}"
export LOOP_NOTIFY="${LOOP_NOTIFY:-}"
export LOOP_EXTRA_PATH="${LOOP_EXTRA_PATH:-/opt/homebrew/bin:/usr/local/bin}"

# Ensure PATH has what we need
export PATH="${LOOP_EXTRA_PATH}:${PATH}"
export HOME="${HOME:-$(eval echo "~$(whoami)")}"

# Ensure log dir exists
mkdir -p "$LOOP_LOG_DIR"

# Helper: run orchestrator (or fallback to claude directly)
loop_run_orchestrator() {
    local prompt="$1"
    local cwd="${2:-$(pwd)}"

    if [ -n "$LOOP_ORCHESTRATOR" ] && [ -x "$LOOP_ORCHESTRATOR" ]; then
        "$LOOP_ORCHESTRATOR" "$prompt" --cwd "$cwd"
    else
        # Direct claude invocation (works for anyone with Claude CLI)
        claude -p --model sonnet --output-format text \
            --dangerously-skip-permissions \
            "$prompt"
    fi
}
