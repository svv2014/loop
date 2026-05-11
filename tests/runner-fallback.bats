#!/usr/bin/env bats
# tests/runner-fallback.bats — unit tests for lib/runner.sh fallback chain.
#
# All agent CLIs are stubbed; no real network or CLI is required.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Stub directory that overrides real agent CLIs
    STUB_DIR="$BATS_TMPDIR/stubs"
    mkdir -p "$STUB_DIR"

    # Attempt log: each stub records its invocation
    ATTEMPTS_LOG="$BATS_TMPDIR/attempts.log"
    rm -f "$ATTEMPTS_LOG"
    export ATTEMPTS_LOG

    # Export env expected by runner.sh
    export LOOP_AGENT="claude"
    unset LOOP_AGENT_CMD LOOP_ORCHESTRATOR LOOP_SENIOR_MODEL LOOP_AGENT_MODEL
    unset _PROJECT_AGENT _PROJECT_MODEL _PROJECT_FALLBACK

    # Prepend stubs to PATH
    export PATH="$STUB_DIR:$PATH"

    # shellcheck source=../lib/runner.sh
    source "$REPO_ROOT/lib/runner.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/stubs" "$BATS_TMPDIR/attempts.log" 2>/dev/null || true
    unset LOOP_AGENT LOOP_AGENT_CMD LOOP_AGENT_MODEL LOOP_ORCHESTRATOR
    unset _PROJECT_AGENT _PROJECT_MODEL _PROJECT_FALLBACK ATTEMPTS_LOG
}

# ─── Stub helpers ────────────────────────────────────────────────────────────

# make_stub <name> <exit_code> [stderr_message]
# Creates an executable stub in $STUB_DIR that logs its name and exits with
# the given code, optionally printing a message to stderr.
make_stub() {
    local name="$1"
    local exit_code="$2"
    local stderr_msg="${3:-}"
    cat > "$STUB_DIR/$name" <<STUB
#!/usr/bin/env bash
echo "$name" >> "\$ATTEMPTS_LOG"
${stderr_msg:+echo "$stderr_msg" >&2}
exit $exit_code
STUB
    chmod +x "$STUB_DIR/$name"
}

# ─── Tests ───────────────────────────────────────────────────────────────────

@test "primary success — no fallback attempted, exit 0" {
    make_stub claude 0
    export LOOP_AGENT="claude"
    unset _PROJECT_FALLBACK

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    # Only one attempt
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 1 ]
    grep -q "claude" "$ATTEMPTS_LOG"
}

@test "primary recoverable error (401) — first fallback runs and succeeds, exit 0" {
    make_stub claude  1 "HTTP 401 Unauthorized"
    make_stub codex   0
    export LOOP_AGENT="claude"
    export _PROJECT_FALLBACK="codex||"

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 2 ]
    grep -q "claude" "$ATTEMPTS_LOG"
    grep -q "codex"  "$ATTEMPTS_LOG"
}

@test "two consecutive recoverable errors — third agent (gemini) succeeds, exit 0" {
    make_stub claude 1 "rate limit exceeded"
    make_stub codex  1 "429 Too Many Requests"
    make_stub gemini 0
    export LOOP_AGENT="claude"
    export _PROJECT_FALLBACK="$(printf 'codex||\ngemini||')"

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 3 ]
    grep -q "claude" "$ATTEMPTS_LOG"
    grep -q "codex"  "$ATTEMPTS_LOG"
    grep -q "gemini" "$ATTEMPTS_LOG"
}

@test "primary unrecoverable error (no signal pattern) — no fallback, error propagated" {
    make_stub claude 1 "SyntaxError: unexpected token"
    make_stub codex  0
    export LOOP_AGENT="claude"
    export _PROJECT_FALLBACK="codex||"

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -ne 0 ]
    # Only the primary was invoked; codex fallback must NOT run
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 1 ]
    grep -q "claude" "$ATTEMPTS_LOG"
    ! grep -q "codex" "$ATTEMPTS_LOG"
}

@test "all fallbacks exhausted — final non-zero exit propagated with summary" {
    make_stub claude 1 "503 Service Unavailable"
    make_stub codex  1 "503 Service Unavailable"
    make_stub gemini 1 "connection refused"
    export LOOP_AGENT="claude"
    export _PROJECT_FALLBACK="$(printf 'codex||\ngemini||')"

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 3 ]
    # Summary line must mention attempts
    [[ "$output" == *"attempt"* ]]
}

@test "no agent/model/fallback in project — uses global LOOP_AGENT, no chain" {
    make_stub claude 0
    export LOOP_AGENT="claude"
    unset _PROJECT_AGENT _PROJECT_MODEL _PROJECT_FALLBACK

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 1 ]
    grep -q "claude" "$ATTEMPTS_LOG"
}

@test "agent: custom fallback runs the configured cmd" {
    # Primary agent fails recoverably; fallback uses custom cmd (a stub script)
    make_stub claude 1 "timeout: connection timed out"

    # Custom command is a script that logs and exits 0
    local custom_script="$BATS_TMPDIR/my-local-model.sh"
    cat > "$custom_script" <<'SH'
#!/usr/bin/env bash
echo "custom-local-model" >> "$ATTEMPTS_LOG"
exit 0
SH
    chmod +x "$custom_script"

    export LOOP_AGENT="claude"
    # fallback entry: agent=custom, model="", cmd=<path>
    export _PROJECT_FALLBACK="custom||${custom_script}"

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ATTEMPTS_LOG")" -eq 2 ]
    grep -q "claude"            "$ATTEMPTS_LOG"
    grep -q "custom-local-model" "$ATTEMPTS_LOG"
}

@test "custom agent: prompt with shell metacharacters is not evaluated (no injection)" {
    # Prompt contains $(echo INJECTED) — must arrive literally at the custom script.
    local custom_script="$BATS_TMPDIR/safe-custom.sh"
    local received_prompt_file="$BATS_TMPDIR/received_prompt"
    cat > "$custom_script" <<'SH'
#!/usr/bin/env bash
# Record the literal first argument; do NOT eval it.
printf '%s' "$1" > "$BATS_TMPDIR/received_prompt"
exit 0
SH
    chmod +x "$custom_script"

    # Make BATS_TMPDIR available inside the script via env
    export BATS_TMPDIR
    export LOOP_AGENT="custom"
    export LOOP_AGENT_CMD="$custom_script"
    unset _PROJECT_FALLBACK

    local injection_prompt='hello $(echo INJECTED) world'
    run loop_run_agent "$injection_prompt" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]

    # The word INJECTED must NOT appear as standalone output (injection guard)
    [[ "$output" != *"INJECTED"* ]]

    # The prompt must have arrived verbatim (not evaluated)
    local received
    received="$(cat "$received_prompt_file")"
    [ "$received" = "$injection_prompt" ]
}

@test "custom agent: working directory is the cwd argument, not the caller's directory" {
    local fake_worktree
    fake_worktree="$(mktemp -d)"
    local pwd_capture="$BATS_TMPDIR/custom_pwd"

    local custom_script="$BATS_TMPDIR/pwd-recorder.sh"
    cat > "$custom_script" <<SH
#!/usr/bin/env bash
printf '%s' "\$PWD" > "$pwd_capture"
exit 0
SH
    chmod +x "$custom_script"

    export LOOP_AGENT="custom"
    export LOOP_AGENT_CMD="$custom_script"
    unset _PROJECT_FALLBACK

    run loop_run_agent "do something" "$fake_worktree"
    [ "$status" -eq 0 ]

    local recorded_pwd
    recorded_pwd="$(cat "$pwd_capture")"
    [ "$recorded_pwd" = "$fake_worktree" ]

    rm -rf "$fake_worktree"
}

@test "claude branch never passes --cwd flag (regression of LOOP-29 / LOOP-152)" {
    # Stub records full argv so we can assert no --cwd is passed.
    cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude $*" >> "$ATTEMPTS_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/claude"

    export LOOP_AGENT="claude"
    unset _PROJECT_FALLBACK

    run loop_run_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    ! grep -q -- "--cwd" "$ATTEMPTS_LOG"

    rm -f "$ATTEMPTS_LOG"

    run loop_run_senior_agent "do something" "$BATS_TMPDIR"
    [ "$status" -eq 0 ]
    ! grep -q -- "--cwd" "$ATTEMPTS_LOG"
}
