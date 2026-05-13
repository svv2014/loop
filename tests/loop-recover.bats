#!/usr/bin/env bats
# tests/loop-recover.bats — unit tests for scripts/loop-recover.sh.
#
# Each test:
#   - provides a fixture event log (LOOP_MONITOR_LOG)
#   - stubs gh via a mock binary on PATH
#   - runs loop-recover.sh as a subprocess
#   - asserts correct label add/remove operations and comment posting
#
# No real GitHub calls are made.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"

    # Isolate logs and config from the operator's real files.
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress loop.env loading (no real env file in tests).
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"

    # Minimal project fixture — uses the default workflow so label names are
    # deterministic: needs-dev, needs-review, needs-qa, qa-pass, needs-po.
    cat > "$BATS_TMPDIR/fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: test-proj
    name: Test Project
    repo: owner/test-repo
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML

    # Event log (populated per-test).
    export LOOP_MONITOR_LOG="$BATS_TMPDIR/events.jsonl"
    rm -f "$LOOP_MONITOR_LOG"

    # gh operations log — written by the mock gh binary.
    export GH_OPS_LOG="$BATS_TMPDIR/gh-ops.log"
    rm -f "$GH_OPS_LOG"

    # Put mock gh on PATH before real gh.
    # LOOP_EXTRA_PATH is prepended to PATH by lib/env.sh, so we must include
    # the mock bin dir there to ensure our stub wins over the system gh.
    mkdir -p "$BATS_TMPDIR/bin"
    export LOOP_EXTRA_PATH="$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'GHSH'
#!/usr/bin/env bash
# Mock gh: log every invocation; return fixture data for view queries.
printf 'gh %s\n' "$*" >> "$GH_OPS_LOG"
args="$*"
case "$args" in
    *"--json labels"*)
        # Return current labels CSV via jq-style output.
        printf '%s\n' "${GH_MOCK_LABELS:-}"
        ;;
    *"--json comments"*)
        # Return last comment body string.
        printf '%s\n' "${GH_MOCK_LAST_COMMENT:-}"
        ;;
    *"pr view"*"--json number"*)
        # Succeed only when ticket is a PR.
        exit "${GH_MOCK_IS_PR:-1}"
        ;;
    *"issue view"*"--json number"*)
        # Always succeed (ticket exists as issue).
        printf '{"number":%s}\n' "${GH_MOCK_TICKET:-42}"
        ;;
esac
exit "${GH_MOCK_EXIT:-0}"
GHSH
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Default: ticket is an issue, no current pipeline labels, no prior comment.
    export GH_MOCK_IS_PR=1       # non-zero → gh pr view exits 1 (not a PR)
    export GH_MOCK_LABELS=""     # empty → no current labels
    export GH_MOCK_LAST_COMMENT=""
    export GH_MOCK_TICKET=42
    export GH_MOCK_EXIT=0
}

teardown() {
    rm -rf "$BATS_TMPDIR/fixture.yaml" \
           "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/bin" \
           "$BATS_TMPDIR/events.jsonl" \
           "$BATS_TMPDIR/gh-ops.log" 2>/dev/null || true
}

# Helper: write a single *_done event to the event log.
_write_event() {
    local event_type="$1" issue_num="$2"
    printf '{"type":"%s","payload":{"project":"test-proj","issue_num":%s}}\n' \
        "$event_type" "$issue_num" >> "$LOOP_MONITOR_LOG"
}

# ---------------------------------------------------------------------------
# Stage 1 — po_done → recover to dev (needs-dev)
# ---------------------------------------------------------------------------

@test "recover: po_done event → adds needs-dev label" {
    _write_event "po_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "add-label needs-dev" "$GH_OPS_LOG"
}

@test "recover: po_done event → does not add needs-po (removes old stage)" {
    export GH_MOCK_LABELS="needs-po"
    _write_event "po_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "remove-label needs-po" "$GH_OPS_LOG"
    grep -q "add-label needs-dev" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Stage 2 — dev_done → recover to review (needs-review)
# ---------------------------------------------------------------------------

@test "recover: dev_done event → adds needs-review label" {
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "add-label needs-review" "$GH_OPS_LOG"
}

@test "recover: dev_done event → strips needs-dev when present" {
    export GH_MOCK_LABELS="needs-dev"
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "remove-label needs-dev" "$GH_OPS_LOG"
    grep -q "add-label needs-review" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Stage 3 — review_done → recover to qa (needs-qa)
# ---------------------------------------------------------------------------

@test "recover: review_done event → adds needs-qa label" {
    _write_event "review_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "add-label needs-qa" "$GH_OPS_LOG"
}

@test "recover: review_done event → strips needs-review when present" {
    export GH_MOCK_LABELS="needs-review"
    _write_event "review_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "remove-label needs-review" "$GH_OPS_LOG"
    grep -q "add-label needs-qa" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Stage 4 — qa_done → recover to merge (qa-pass)
# ---------------------------------------------------------------------------

@test "recover: qa_done event → adds qa-pass label" {
    _write_event "qa_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "add-label qa-pass" "$GH_OPS_LOG"
}

@test "recover: qa_done event → strips needs-qa when present" {
    export GH_MOCK_LABELS="needs-qa"
    _write_event "qa_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "remove-label needs-qa" "$GH_OPS_LOG"
    grep -q "add-label qa-pass" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Stage 5 — --to-stage po → adds needs-po
# ---------------------------------------------------------------------------

@test "recover: --to-stage po → adds needs-po label without reading event log" {
    # No event log needed when --to-stage is given.
    export GH_MOCK_LABELS="needs-dev"

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --to-stage po
    [ "$status" -eq 0 ]

    grep -q "add-label needs-po" "$GH_OPS_LOG"
    grep -q "remove-label needs-dev" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# --to-stage overrides for all stages
# ---------------------------------------------------------------------------

@test "recover: --to-stage dev → adds needs-dev" {
    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --to-stage dev
    [ "$status" -eq 0 ]
    grep -q "add-label needs-dev" "$GH_OPS_LOG"
}

@test "recover: --to-stage review → adds needs-review" {
    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --to-stage review
    [ "$status" -eq 0 ]
    grep -q "add-label needs-review" "$GH_OPS_LOG"
}

@test "recover: --to-stage qa → adds needs-qa" {
    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --to-stage qa
    [ "$status" -eq 0 ]
    grep -q "add-label needs-qa" "$GH_OPS_LOG"
}

@test "recover: --to-stage merge → adds qa-pass" {
    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --to-stage merge
    [ "$status" -eq 0 ]
    grep -q "add-label qa-pass" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# --dry-run
# ---------------------------------------------------------------------------

@test "recover --dry-run: prints planned operations, no gh edit calls" {
    export GH_MOCK_LABELS="needs-dev"
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --dry-run
    [ "$status" -eq 0 ]

    # Dry-run output must mention what would happen.
    printf '%s\n' "$output" | grep -q "would add label"
    printf '%s\n' "$output" | grep -q "would remove label"

    # No real gh edit calls must occur.
    ! grep -q "issue edit" "$GH_OPS_LOG" || ! grep -q "pr edit" "$GH_OPS_LOG"
}

@test "recover --dry-run: prints comment body" {
    _write_event "qa_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --dry-run
    [ "$status" -eq 0 ]

    printf '%s\n' "$output" | grep -q "would post comment"
    printf '%s\n' "$output" | grep -q "Loop recovery"
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "recover: idempotent — already at target stage, no label changes" {
    # Ticket already carries needs-review (the dev_done target stage).
    export GH_MOCK_LABELS="needs-review"
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    # No add-label or remove-label calls.
    ! grep -q "add-label" "$GH_OPS_LOG"
    ! grep -q "remove-label" "$GH_OPS_LOG"
}

@test "recover: idempotent — second run skips comment when last comment has recovery marker" {
    export GH_MOCK_LAST_COMMENT="**Loop recovery** — operator rolled ticket #42 back to stage"
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    # No issue comment or pr comment call.
    ! grep -q "issue comment" "$GH_OPS_LOG"
    ! grep -q "pr comment" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Most-recent-event wins (last *_done in log takes precedence)
# ---------------------------------------------------------------------------

@test "recover: most recent done event wins when log has multiple events" {
    # Older event: po_done → dev; newer event: dev_done → review
    _write_event "po_done" 42
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    # Must target review (dev_done), NOT dev (po_done).
    grep -q "add-label needs-review" "$GH_OPS_LOG"
    ! grep -q "add-label needs-dev" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "recover: exits non-zero when no event log and no --to-stage" {
    rm -f "$LOOP_MONITOR_LOG"

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -qi "event log"
}

@test "recover: exits non-zero when no matching event for ticket" {
    # Event is for ticket #99, not #42.
    _write_event "dev_done" 99

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -qi "no known-good stage"
}

@test "recover: exits non-zero for unknown --to-stage value" {
    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj --to-stage invalid
    [ "$status" -ne 0 ]
}

@test "recover: exits non-zero when ticket number is missing" {
    run "$REPO_ROOT/scripts/loop-recover.sh" --slug test-proj
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Flat event log format (bounty-style)
# ---------------------------------------------------------------------------

@test "recover: parses flat event format {event:..., issue_num:...}" {
    printf '{"event":"review_done","project":"test-proj","issue_num":42}\n' \
        >> "$LOOP_MONITOR_LOG"

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "add-label needs-qa" "$GH_OPS_LOG"
}

# ---------------------------------------------------------------------------
# Comment is posted on real run
# ---------------------------------------------------------------------------

@test "recover: posts comment on issue when not already recovered" {
    _write_event "dev_done" 42

    run "$REPO_ROOT/scripts/loop-recover.sh" 42 --slug test-proj
    [ "$status" -eq 0 ]

    grep -q "issue comment" "$GH_OPS_LOG"
}
