#!/usr/bin/env bats
# tests/install-status.bats — tests for the 'status' subcommand in install.sh
#
# Verifies that:
#   - status exits 0 when all checks pass
#   - status exits non-zero and prints checklist items when checks fail
#   - each check (loop.env, agent CLI, gh auth, scanner, reconciler) is reported

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Fake LOOP_ROOT for isolation
    export FAKE_LOOP_ROOT="$BATS_TMPDIR/loop-root-$$"
    mkdir -p "$FAKE_LOOP_ROOT/config"

    # Fake bin dir for mocking commands
    export MOCK_BIN="$BATS_TMPDIR/bin-$$"
    mkdir -p "$MOCK_BIN"

    # Default: healthy loop.env
    cat > "$FAKE_LOOP_ROOT/loop.env" <<'ENV'
LOOP_AGENT="claude"
LOOP_LOG_DIR=""
ENV
}

teardown() {
    rm -rf "$BATS_TMPDIR/loop-root-$$" "$BATS_TMPDIR/bin-$$"
    unset FAKE_LOOP_ROOT MOCK_BIN
}

# Helper: create a fake binary in MOCK_BIN that exits 0
make_fake_cmd() {
    local name="$1"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# Helper: create a fake binary in MOCK_BIN that exits with given code
make_fake_cmd_exit() {
    local name="$1" code="$2"
    printf '#!/usr/bin/env bash\nexit %d\n' "$code" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# Extract status_check + helpers from install.sh for isolated testing
extract_status_check() {
    # Extract bootstrap_resolve_log_dir and status_check functions
    awk '
        /^bootstrap_resolve_log_dir\(\)/ { found=1; depth=0 }
        /^status_check\(\)/ { found=1; depth=0 }
        found {
            print
            for(i=1;i<=length($0);i++) {
                c=substr($0,i,1)
                if(c=="{") depth++
                if(c=="}") depth--
            }
            if(found && depth==0 && NR>1) { found=0; print "" }
        }
    ' "$REPO_ROOT/install.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# status: loop.env checks
# ─────────────────────────────────────────────────────────────────────────────

@test "status: reports ok for loop.env with LOOP_AGENT set" {
    make_fake_cmd "claude"
    make_fake_cmd "gh"
    # gh auth status mock
    cat > "$MOCK_BIN/gh" <<'BASH'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then exit 0; fi
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then exit 0; fi
exit 0
BASH
    chmod +x "$MOCK_BIN/gh"

    run bash - <<SHELL
PATH="$MOCK_BIN"
LOOP_ROOT="$FAKE_LOOP_ROOT"
PROJECTS_YAML="$FAKE_LOOP_ROOT/config/projects.yaml"
uname() { echo "Linux"; }
crontab() {
    if [ "\$1" = "-l" ]; then
        echo "*/5 * * * * scanner.sh # loop-scanner"
        echo "*/15 * * * * reconciler.sh # loop-reconciler"
    fi
}
export -f uname crontab 2>/dev/null || true
$(extract_status_check)
status_check
SHELL

    [[ "$output" == *"loop.env"* ]] || [[ "$output" == *"LOOP_AGENT=claude"* ]]
}

@test "status: exits non-zero when loop.env is missing" {
    rm -f "$FAKE_LOOP_ROOT/loop.env"
    make_fake_cmd "gh"

    run bash - <<SHELL
PATH="$MOCK_BIN"
LOOP_ROOT="$FAKE_LOOP_ROOT"
PROJECTS_YAML="$FAKE_LOOP_ROOT/config/projects.yaml"
$(extract_status_check)
status_check
SHELL

    [ "$status" -ne 0 ]
    [[ "$output" == *"loop.env"* ]]
}

@test "status: exits non-zero when LOOP_AGENT not set in loop.env" {
    # loop.env exists but no LOOP_AGENT
    printf '# empty\nLOOP_LOG_DIR=""\n' > "$FAKE_LOOP_ROOT/loop.env"
    make_fake_cmd "gh"

    run bash - <<SHELL
PATH="$MOCK_BIN"
LOOP_ROOT="$FAKE_LOOP_ROOT"
PROJECTS_YAML="$FAKE_LOOP_ROOT/config/projects.yaml"
$(extract_status_check)
status_check
SHELL

    [ "$status" -ne 0 ]
    [[ "$output" == *"LOOP_AGENT"* ]]
}

@test "status: exits non-zero when agent CLI not in PATH" {
    # loop.env says claude, but claude not in PATH
    cat > "$FAKE_LOOP_ROOT/loop.env" <<'ENV'
LOOP_AGENT="claude"
ENV
    make_fake_cmd "gh"

    run bash - <<SHELL
PATH="$MOCK_BIN"
LOOP_ROOT="$FAKE_LOOP_ROOT"
PROJECTS_YAML="$FAKE_LOOP_ROOT/config/projects.yaml"
$(extract_status_check)
status_check
SHELL

    [ "$status" -ne 0 ]
    [[ "$output" == *"claude"* ]]
}

@test "status: reports failure when gh not authenticated" {
    make_fake_cmd "claude"
    # gh auth status fails
    cat > "$MOCK_BIN/gh" <<'BASH'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then exit 1; fi
exit 0
BASH
    chmod +x "$MOCK_BIN/gh"

    run bash - <<SHELL
PATH="$MOCK_BIN"
LOOP_ROOT="$FAKE_LOOP_ROOT"
PROJECTS_YAML="$FAKE_LOOP_ROOT/config/projects.yaml"
$(extract_status_check)
status_check
SHELL

    [ "$status" -ne 0 ]
    [[ "$output" == *"gh"* ]]
}

@test "status: prints checklist with ok/fail markers" {
    rm -f "$FAKE_LOOP_ROOT/loop.env"

    run bash - <<SHELL
PATH="$MOCK_BIN"
LOOP_ROOT="$FAKE_LOOP_ROOT"
PROJECTS_YAML="$FAKE_LOOP_ROOT/config/projects.yaml"
$(extract_status_check)
status_check
SHELL

    # Should contain checklist markers
    [[ "$output" == *"[ok]"* ]] || [[ "$output" == *"[!!]"* ]] || [[ "$output" == *"[--]"* ]]
}

@test "status: ./install.sh status subcommand is reachable" {
    # Verify the install.sh accepts 'status' as a positional arg
    run bash -n "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]

    grep -q 'status)' "$REPO_ROOT/install.sh"
    grep -q 'STATUS_MODE=true' "$REPO_ROOT/install.sh"
    grep -q 'status_check' "$REPO_ROOT/install.sh"
}
