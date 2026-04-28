#!/usr/bin/env bats
# tests/digest.bats — unit tests for scanner/digest.sh
#
# Uses synthetic fixture data and a mock gh binary.
# No live gh calls are made.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Wire up mock gh
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress LOOP_EXTRA_PATH so env.sh doesn't shadow our mock gh
    export LOOP_EXTRA_PATH=""
    export LOOP_NOTIFY=""
    export LOOP_HANDLER_TIMEOUT="7200"

    # Two-project fixture: alpha + beta
    cat > "$BATS_TMPDIR/projects.yaml" <<'YAML'
version: 1
projects:
  - slug: alpha
    name: Alpha Project
    repo: owner/alpha
    root: /tmp/fake-alpha
    default_branch: main
  - slug: beta
    name: Beta Project
    repo: owner/beta
    root: /tmp/fake-beta
    default_branch: main
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/projects.yaml"

    # Shared mock-gh response control
    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/projects.yaml" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: build digest from a custom mock-gh script
# Writes a per-test gh script that returns fixture data based on the call args.
# ---------------------------------------------------------------------------

make_mock_gh() {
    # $1 = path to write mock script
    # $2 = shell snippet to embed (receives "$@" as gh args)
    local dest="$1" snippet="$2"
    # Remove any existing symlink before writing so we don't corrupt the target.
    rm -f "$dest"
    cat > "$dest" <<SCRIPT
#!/usr/bin/env bash
${snippet}
exit 0
SCRIPT
    chmod +x "$dest"
}

# ---------------------------------------------------------------------------
# Fixture helpers — produce minimal gh JSON output
# ---------------------------------------------------------------------------

issue_json() {
    # $1=number $2=title $3=label $4=updatedAt(ISO8601)
    printf '[{"number":%s,"title":"%s","labels":[{"name":"%s"}],"updatedAt":"%s","createdAt":"%s"}]' \
        "$1" "$2" "$3" "$4" "$4"
}

empty_json() { printf '[]'; }

# ---------------------------------------------------------------------------
# Test 1: zero stuck items → digest suppressed (no output, exit 0)
# ---------------------------------------------------------------------------

@test "digest suppressed when no stuck items exist" {
    make_mock_gh "$BATS_TMPDIR/bin/gh" "printf '[]'"

    run bash "$REPO_ROOT/scanner/digest.sh" --dry-run
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 2: 3 stuck items in 2 projects → digest contains expected entries
# ---------------------------------------------------------------------------

@test "digest includes 3 stuck items from 2 projects" {
    # alpha: issue #1 needs-clarification, issue #2 blocked
    # beta:  issue #5 needs-clarification
    # All updatedAt set to far in the past (2000h ago) so age math is reliable.
    local old_ts="2020-01-01T00:00:00Z"
    local alpha_nc; alpha_nc=$(issue_json 1 "Alpha needs input" "needs-clarification" "$old_ts")
    local alpha_bl; alpha_bl=$(issue_json 2 "Alpha is blocked" "blocked" "$old_ts")
    local beta_nc;  beta_nc=$(issue_json 5 "Beta needs input" "needs-clarification" "$old_ts")

    # Mock gh: dispatch on repo + label args
    make_mock_gh "$BATS_TMPDIR/bin/gh" "
case \"\$*\" in
    *'owner/alpha'*'needs-clarification'*)  printf '%s' '${alpha_nc}' ;;
    *'owner/alpha'*'blocked'*)             printf '%s' '${alpha_bl}' ;;
    *'owner/alpha'*'in-progress'*)         printf '[]' ;;
    *'owner/alpha'*'in-review'*)           printf '[]' ;;
    *'owner/alpha'*'in-rework'*)           printf '[]' ;;
    *'owner/beta'*'needs-clarification'*)  printf '%s' '${beta_nc}' ;;
    *'owner/beta'*'blocked'*)              printf '[]' ;;
    *'owner/beta'*'in-progress'*)          printf '[]' ;;
    *'owner/beta'*'in-review'*)            printf '[]' ;;
    *'owner/beta'*'in-rework'*)            printf '[]' ;;
    # issue view for last comment
    *'issue view'*)                         printf '{\"comments\":[{\"body\":\"last comment here\"}]}' ;;
    *)                                      printf '[]' ;;
esac
"

    run bash "$REPO_ROOT/scanner/digest.sh" --dry-run
    [ "$status" -eq 0 ]

    # Digest header present
    [[ "$output" == *"Loop Digest"* ]]

    # Both projects appear
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]

    # All three issue numbers appear
    [[ "$output" == *"#1"* ]]
    [[ "$output" == *"#2"* ]]
    [[ "$output" == *"#5"* ]]

    # Labels appear
    [[ "$output" == *"needs-clarification"* ]]
    [[ "$output" == *"blocked"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: entries sorted by age (oldest first within each project)
# ---------------------------------------------------------------------------

@test "entries are sorted oldest-first within each project" {
    # Issue #10 updated 1h ago, issue #20 updated 100h ago → #20 should appear first
    local recent_ts; recent_ts=$(python3 -c "
import datetime as dt
now = dt.datetime.now(dt.timezone.utc)
print((now - dt.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    local old_ts; old_ts=$(python3 -c "
import datetime as dt
now = dt.datetime.now(dt.timezone.utc)
print((now - dt.timedelta(hours=100)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")

    local iss10; iss10=$(issue_json 10 "Recent issue" "needs-clarification" "$recent_ts")
    local iss20; iss20=$(issue_json 20 "Old issue" "blocked" "$old_ts")

    make_mock_gh "$BATS_TMPDIR/bin/gh" "
case \"\$*\" in
    *'owner/alpha'*'needs-clarification'*) printf '%s' '${iss10}' ;;
    *'owner/alpha'*'blocked'*)            printf '%s' '${iss20}' ;;
    *'owner/alpha'*) printf '[]' ;;
    *'owner/beta'*)  printf '[]' ;;
    *'issue view'*)  printf '{\"comments\":[]}' ;;
    *)               printf '[]' ;;
esac
"
    # Strip beta project from fixture so only alpha matters
    cat > "$BATS_TMPDIR/projects.yaml" <<'YAML'
version: 1
projects:
  - slug: alpha
    name: Alpha
    repo: owner/alpha
    root: /tmp/fake-alpha
    default_branch: main
YAML

    run bash "$REPO_ROOT/scanner/digest.sh" --dry-run
    [ "$status" -eq 0 ]

    # #20 (older) must appear before #10 (newer)
    local pos10 pos20
    pos10=$(echo "$output" | grep -n '#10' | cut -d: -f1 | head -1)
    pos20=$(echo "$output" | grep -n '#20' | cut -d: -f1 | head -1)
    [ -n "$pos10" ] && [ -n "$pos20" ]
    [ "$pos20" -lt "$pos10" ]
}

# ---------------------------------------------------------------------------
# Test 4: operational labels stuck >2× HANDLER_TIMEOUT are included
# ---------------------------------------------------------------------------

@test "in-progress issue stuck over 2x HANDLER_TIMEOUT is included" {
    export LOOP_HANDLER_TIMEOUT="3600"  # 1h → threshold = 2h

    # Issue updated 3h ago — should be included
    local old_ts; old_ts=$(python3 -c "
import datetime as dt
now = dt.datetime.now(dt.timezone.utc)
print((now - dt.timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    local ip_iss; ip_iss=$(issue_json 42 "Stuck in progress" "in-progress" "$old_ts")

    cat > "$BATS_TMPDIR/projects.yaml" <<'YAML'
version: 1
projects:
  - slug: alpha
    name: Alpha
    repo: owner/alpha
    root: /tmp/fake-alpha
    default_branch: main
YAML

    make_mock_gh "$BATS_TMPDIR/bin/gh" "
case \"\$*\" in
    *'owner/alpha'*'needs-clarification'*) printf '[]' ;;
    *'owner/alpha'*'blocked'*)            printf '[]' ;;
    *'owner/alpha'*'in-progress'*)        printf '%s' '${ip_iss}' ;;
    *'owner/alpha'*'in-review'*)          printf '[]' ;;
    *'owner/alpha'*'in-rework'*)          printf '[]' ;;
    *'issue view'*)                        printf '{\"comments\":[]}' ;;
    *)                                     printf '[]' ;;
esac
"

    run bash "$REPO_ROOT/scanner/digest.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"in-progress"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: operational label NOT yet over threshold → excluded
# ---------------------------------------------------------------------------

@test "in-progress issue under 2x HANDLER_TIMEOUT threshold is excluded" {
    export LOOP_HANDLER_TIMEOUT="7200"  # 2h → threshold = 4h

    # Issue updated 1h ago — below threshold
    local recent_ts; recent_ts=$(python3 -c "
import datetime as dt
now = dt.datetime.now(dt.timezone.utc)
print((now - dt.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
    local ip_iss; ip_iss=$(issue_json 99 "Fresh in progress" "in-progress" "$recent_ts")

    cat > "$BATS_TMPDIR/projects.yaml" <<'YAML'
version: 1
projects:
  - slug: alpha
    name: Alpha
    repo: owner/alpha
    root: /tmp/fake-alpha
    default_branch: main
YAML

    make_mock_gh "$BATS_TMPDIR/bin/gh" "
case \"\$*\" in
    *'owner/alpha'*'needs-clarification'*) printf '[]' ;;
    *'owner/alpha'*'blocked'*)            printf '[]' ;;
    *'owner/alpha'*'in-progress'*)        printf '%s' '${ip_iss}' ;;
    *'owner/alpha'*'in-review'*)          printf '[]' ;;
    *'owner/alpha'*'in-rework'*)          printf '[]' ;;
    *)                                     printf '[]' ;;
esac
"

    run bash "$REPO_ROOT/scanner/digest.sh" --dry-run
    [ "$status" -eq 0 ]
    # No output = digest suppressed = no stuck items
    [ -z "$output" ]
}
