#!/usr/bin/env bats
# tests/install-bootstrap-detect.bats — tests for bootstrap agent auto-detect in install.sh
#
# Verifies that:
#   - bootstrap with each of claude/codex/gemini/aider available picks the right one
#   - bootstrap with no agent found exits non-zero with a useful error message

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Isolated temp directory for each test
    export TEST_HOME="$BATS_TMPDIR/home-$$"
    mkdir -p "$TEST_HOME"

    # Fake bin directory for mocking agent CLIs
    export MOCK_BIN="$BATS_TMPDIR/bin-$$"
    mkdir -p "$MOCK_BIN"

    # Isolated loop.env location — use a temp LOOP_ROOT
    export FAKE_LOOP_ROOT="$BATS_TMPDIR/loop-root-$$"
    mkdir -p "$FAKE_LOOP_ROOT/config"
    cp "$REPO_ROOT/loop.env.example" "$FAKE_LOOP_ROOT/"
    touch "$FAKE_LOOP_ROOT/config/projects.example.yaml"

    # Stub out heavy bootstrap functions — we only want to test agent detect
    # We do this by sourcing install.sh with the right env substitutions
    export AGENT_DETECT_ONLY=1
}

teardown() {
    rm -rf "$BATS_TMPDIR/home-$$" "$BATS_TMPDIR/bin-$$" "$BATS_TMPDIR/loop-root-$$"
    unset TEST_HOME MOCK_BIN FAKE_LOOP_ROOT AGENT_DETECT_ONLY
}

# Helper: create a fake agent binary in MOCK_BIN
make_fake_agent() {
    local name="$1"
    printf '#!/usr/bin/env bash\necho "%s mock"\n' "$name" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# Helper: run bootstrap_detect_agent in an isolated subshell with controlled PATH
run_detect_agent() {
    local mock_path="$1"
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    # Source only the bootstrap_detect_agent function from install.sh
    # and run it in a controlled environment
    bash - <<SHELL
set -euo pipefail
PATH="$mock_path:\$PATH"
LOOP_ROOT="$FAKE_LOOP_ROOT"
$(grep -A 60 '^bootstrap_detect_agent()' "$REPO_ROOT/install.sh" | \
  awk '/^bootstrap_detect_agent\(\)/{found=1} found{print} found && /^\}$/{exit}')
bootstrap_detect_agent
SHELL
}

# ─────────────────────────────────────────────────────────────────────────────
# Agent detection — each agent in isolation
# ─────────────────────────────────────────────────────────────────────────────

# Helper: extract bootstrap_detect_agent function body from install.sh
_extract_detect_func() {
    awk '
        /^bootstrap_detect_agent\(\)/ { found=1; depth=0 }
        found {
            for(i=1;i<=length($0);i++) {
                c=substr($0,i,1)
                if(c=="{") depth++
                if(c=="}") depth--
            }
            print
            if(depth==0 && NR>1) { found=0 }
        }
    ' "$REPO_ROOT/install.sh"
}

# Helper: run bootstrap_detect_agent with only the specified agents "available".
# Uses a command() override to intercept command -v calls for agent names.
# Keeps system PATH for tools like python3, grep etc.
run_detect_only_agents() {
    local available_agents=("$@")
    local loop_env="$FAKE_LOOP_ROOT/loop.env"

    # Build a space-separated list for the subshell
    local agents_list="${available_agents[*]}"

    local func_body
    func_body=$(_extract_detect_func)

    bash -c "
set -euo pipefail
LOOP_ROOT=\"$FAKE_LOOP_ROOT\"

# Override 'command' to control which agents are 'found'
# Only the agents in _AVAIL_AGENTS are reported as available
_AVAIL_AGENTS=\" ${agents_list} \"
command() {
    if [ \"\${1:-}\" = \"-v\" ]; then
        local name=\"\${2:-}\"
        case \"\$name\" in
            claude|codex|gemini|aider)
                if [[ \"\$_AVAIL_AGENTS\" == *\" \$name \"* ]]; then
                    echo \"/mock/\$name\"
                    return 0
                else
                    return 1
                fi
                ;;
        esac
    fi
    builtin command \"\$@\"
}
export -f command 2>/dev/null || true

${func_body}
bootstrap_detect_agent
"
    local rc=$?
    return $rc
}

@test "bootstrap_detect_agent: detects 'claude' when only claude is in PATH" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    run_detect_only_agents "claude"
    grep -q 'LOOP_AGENT="claude"' "$loop_env"
}

@test "bootstrap_detect_agent: detects 'codex' when only codex is in PATH" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    run_detect_only_agents "codex"
    grep -q 'LOOP_AGENT="codex"' "$loop_env"
}

@test "bootstrap_detect_agent: detects 'gemini' when only gemini is in PATH" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    run_detect_only_agents "gemini"
    grep -q 'LOOP_AGENT="gemini"' "$loop_env"
}

@test "bootstrap_detect_agent: detects 'aider' when only aider is in PATH" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    run_detect_only_agents "aider"
    grep -q 'LOOP_AGENT="aider"' "$loop_env"
}

@test "bootstrap_detect_agent: prefers claude over codex when both present" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    run_detect_only_agents "claude" "codex"
    grep -q 'LOOP_AGENT="claude"' "$loop_env"
}

@test "bootstrap_detect_agent: exits non-zero when no agent found" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    local func_body
    func_body=$(_extract_detect_func)

    # Pass empty list — no agents available
    run bash -c "
set -euo pipefail
LOOP_ROOT=\"$FAKE_LOOP_ROOT\"
_AVAIL_AGENTS=\"  \"
command() {
    if [ \"\${1:-}\" = \"-v\" ]; then
        local name=\"\${2:-}\"
        case \"\$name\" in
            claude|codex|gemini|aider) return 1 ;;
        esac
    fi
    builtin command \"\$@\"
}
export -f command 2>/dev/null || true
${func_body}
bootstrap_detect_agent 2>&1
"
    [ "$status" -ne 0 ]
}

@test "bootstrap_detect_agent: prints actionable error when no agent found" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    local func_body
    func_body=$(_extract_detect_func)

    run bash -c "
LOOP_ROOT=\"$FAKE_LOOP_ROOT\"
_AVAIL_AGENTS=\"  \"
command() {
    if [ \"\${1:-}\" = \"-v\" ]; then
        local name=\"\${2:-}\"
        case \"\$name\" in
            claude|codex|gemini|aider) return 1 ;;
        esac
    fi
    builtin command \"\$@\"
}
export -f command 2>/dev/null || true
${func_body}
bootstrap_detect_agent 2>&1
"
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"gemini"* ]]
    [[ "$output" == *"aider"* ]]
}

@test "bootstrap_detect_agent: updates existing LOOP_AGENT line in loop.env" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    # Simulate already having claude set
    printf 'LOOP_AGENT="claude"\n' > "$loop_env"

    # Only make codex available
    run_detect_only_agents "codex"

    # Should now have codex (the only available agent)
    grep -q 'LOOP_AGENT="codex"' "$loop_env"
    # Should not have duplicate lines
    [ "$(grep -c 'LOOP_AGENT=' "$loop_env")" -eq 1 ]
}

@test "bootstrap_detect_agent: honours LOOP_AGENT env var without probing PATH" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    rm -f "$loop_env"
    cp "$FAKE_LOOP_ROOT/loop.env.example" "$loop_env"

    local func_body
    func_body=$(_extract_detect_func)

    # LOOP_AGENT=gemini is set in the env; no agent CLIs are available in PATH.
    # The function should write gemini to loop.env and exit 0 without failing.
    run bash -c "
set -euo pipefail
LOOP_ROOT=\"$FAKE_LOOP_ROOT\"
LOOP_AGENT=\"gemini\"
export LOOP_AGENT

# Override command -v so no agent CLIs appear in PATH
command() {
    if [ \"\${1:-}\" = \"-v\" ]; then
        local name=\"\${2:-}\"
        case \"\$name\" in
            claude|codex|gemini|aider) return 1 ;;
        esac
    fi
    builtin command \"\$@\"
}
export -f command 2>/dev/null || true

${func_body}
bootstrap_detect_agent
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gemini"* ]]
    grep -q 'LOOP_AGENT="gemini"' "$loop_env"
}

@test "bootstrap_detect_agent: LOOP_AGENT env overrides a different agent already in loop.env" {
    local loop_env="$FAKE_LOOP_ROOT/loop.env"
    # loop.env already has claude
    printf 'LOOP_AGENT="claude"\n' > "$loop_env"

    local func_body
    func_body=$(_extract_detect_func)

    # LOOP_AGENT=aider is in the environment; claude is not in PATH either.
    run bash -c "
set -euo pipefail
LOOP_ROOT=\"$FAKE_LOOP_ROOT\"
LOOP_AGENT=\"aider\"
export LOOP_AGENT

command() {
    if [ \"\${1:-}\" = \"-v\" ]; then
        local name=\"\${2:-}\"
        case \"\$name\" in
            claude|codex|gemini|aider) return 1 ;;
        esac
    fi
    builtin command \"\$@\"
}
export -f command 2>/dev/null || true

${func_body}
bootstrap_detect_agent
"
    [ "$status" -eq 0 ]
    grep -q 'LOOP_AGENT="aider"' "$loop_env"
    # Should not have duplicate lines
    local count
    count=$(grep -c 'LOOP_AGENT=' "$loop_env")
    [ "$count" -eq 1 ]
}
