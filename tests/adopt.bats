#!/usr/bin/env bats
# tests/adopt.bats — tests for scripts/adopt.sh.
#
# Mocks gh via $BATS_TMPDIR/bin/gh using a fixture JSON payload.
# Uses LOOP_PROJECTS_CONFIG to redirect projects.yaml to a temp file.
# Uses LOOP_EXTRA_PATH="" so env.sh does not prepend /opt/homebrew and shadow
# the mock gh binary.

REPO_ROOT() { cd "$BATS_TEST_DIRNAME/.." && pwd; }

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Fake repo dir (adopt.sh checks it exists with [ -d ])
    FAKE_REPO="$BATS_TMPDIR/fake-repo"
    mkdir -p "$FAKE_REPO/.git"

    # Temp projects.yaml path — redirect adopt.sh output here
    PROJECTS_YAML="$BATS_TMPDIR/projects.yaml"
    export LOOP_PROJECTS_CONFIG="$PROJECTS_YAML"

    # Log dir so env.sh doesn't create ~/.loop/logs
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Point LOOP_EXTRA_PATH at our mock bin so env.sh prepends it
    # (empty string would trigger the :-default inside env.sh)
    export LOOP_EXTRA_PATH="$BATS_TMPDIR/bin"

    # Mock gh binary
    mkdir -p "$BATS_TMPDIR/bin"
    GH_MOCK_LOG="$BATS_TMPDIR/gh-calls.log"
    export GH_MOCK_LOG

    GH_LABEL_FIXTURE='[
      {"name":"triage",           "color":"e4e669","description":"needs triage"},
      {"name":"ready-for-review", "color":"0075ca","description":"PR ready for review"},
      {"name":"request-changes",  "color":"e4813b","description":"reviewer requested changes"},
      {"name":"qa-please",        "color":"fbca04","description":"ready for QA"},
      {"name":"ready-to-merge",   "color":"0e8a16","description":"approved, merge when ready"},
      {"name":"qa-broken",        "color":"b60205","description":"QA failed"},
      {"name":"halted",           "color":"b60205","description":"blocked work"},
      {"name":"completed",        "color":"0e8a16","description":"work done"}
    ]'
    export GH_LABEL_FIXTURE

    cat > "$BATS_TMPDIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
[ -n "${GH_MOCK_LOG:-}" ] && printf 'gh %s\n' "$*" >> "$GH_MOCK_LOG"
# Simulate gh repo view -q output (plain value, not JSON)
case "$*" in
    *nameWithOwner*)
        printf 'acme/cool-app\n'; exit 0 ;;
    *defaultBranchRef*)
        printf 'main\n'; exit 0 ;;
    *"label list"*)
        printf '%s\n' "${GH_LABEL_FIXTURE}"; exit 0 ;;
esac
exit 0
MOCK
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    ADOPT_SH="$REPO_ROOT/scripts/adopt.sh"
    export ADOPT_SH FAKE_REPO PROJECTS_YAML
}

teardown() {
    rm -rf "$BATS_TMPDIR/fake-repo" \
           "$BATS_TMPDIR/bin"       \
           "$BATS_TMPDIR/logs"      \
           "$BATS_TMPDIR/gh-calls.log" \
           "$BATS_TMPDIR/projects.yaml" 2>/dev/null || true
    unset LOOP_PROJECTS_CONFIG LOOP_LOG_DIR LOOP_EXTRA_PATH GH_MOCK_LOG GH_LABEL_FIXTURE
}

# ─────────────────────────────────────────────────────────────────────────────

@test "adopt.sh: maps non-canonical labels and writes projects.yaml" {
    run "$ADOPT_SH" "$FAKE_REPO" --auto --slug cool-app

    [ "$status" -eq 0 ]

    # projects.yaml must have been created
    [ -f "$PROJECTS_YAML" ]

    # Slug and repo must appear
    grep -q "slug: cool-app"       "$PROJECTS_YAML"
    grep -q "repo: acme/cool-app"  "$PROJECTS_YAML"

    # Non-canonical labels must appear in the labels map
    grep -q "ready-for-review"  "$PROJECTS_YAML"
    grep -q "ready-to-merge"    "$PROJECTS_YAML"
}

@test "adopt.sh: omits overrides when labels match canonical names" {
    export GH_LABEL_FIXTURE='[
      {"name":"plan",          "color":"e4e669","description":"plan"},
      {"name":"needs-review",  "color":"0075ca","description":"ready for review"},
      {"name":"needs-rework",  "color":"e4813b","description":"needs rework"},
      {"name":"needs-qa",      "color":"fbca04","description":"needs qa"},
      {"name":"qa-pass",       "color":"0e8a16","description":"qa passed"},
      {"name":"qa-fail",       "color":"b60205","description":"qa failed"},
      {"name":"blocked",       "color":"b60205","description":"blocked"},
      {"name":"done",          "color":"0e8a16","description":"done"}
    ]'

    run "$ADOPT_SH" "$FAKE_REPO" --auto --slug exact-match

    [ "$status" -eq 0 ]
    [ -f "$PROJECTS_YAML" ]

    grep -q "slug: exact-match" "$PROJECTS_YAML"
    # No non-canonical overrides should appear
    ! grep -q "^    labels:" "$PROJECTS_YAML"
}

@test "adopt.sh: idempotent — re-run does not duplicate slug entry" {
    run "$ADOPT_SH" "$FAKE_REPO" --auto --slug idem-test
    [ "$status" -eq 0 ]

    run "$ADOPT_SH" "$FAKE_REPO" --auto --slug idem-test
    [ "$status" -eq 0 ]

    COUNT=$(grep -c "slug: idem-test" "$PROJECTS_YAML")
    [ "$COUNT" -eq 1 ]
}

@test "adopt.sh: warns about unmappable canonicals and emits gh create command" {
    export GH_LABEL_FIXTURE='[
      {"name":"triage",          "color":"e4e669","description":"triage"},
      {"name":"ready-for-review","color":"0075ca","description":"ready for review"}
    ]'

    run "$ADOPT_SH" "$FAKE_REPO" --auto --slug warn-test

    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "WARN"
    echo "$output" | grep -qi "gh label create"
}

@test "adopt.sh: calls gh label list with --json flag" {
    run "$ADOPT_SH" "$FAKE_REPO" --auto --slug log-test

    [ "$status" -eq 0 ]
    [ -f "$GH_MOCK_LOG" ]
    grep -q "label list" "$GH_MOCK_LOG"
    grep -q "\-\-json"   "$GH_MOCK_LOG"
}
