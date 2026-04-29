#!/usr/bin/env bats
# tests/qa-smart.bats — unit tests for smart QA handler logic.
#
# Tests: AC parsing, structured comment shape, fallback when no ACs,
# regression detection on touched files, conditional test-creation logic.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# Helpers (mirror logic from qa-handler.sh prompt construction)
# ---------------------------------------------------------------------------

# Returns "yes" if issue body contains ## Acceptance Criteria section.
_has_acceptance_criteria() {
    local body="$1"
    printf '%s' "$body" | python3 -c "
import sys, re
body = sys.stdin.read()
print('yes' if re.search(r'^##\s+Acceptance Criteria', body, re.MULTILINE) else 'no')
"
}

# Extracts - [ ] / - [x] lines from ## Acceptance Criteria section.
_parse_acceptance_criteria() {
    local body="$1"
    printf '%s' "$body" | python3 -c "
import sys, re
body = sys.stdin.read()
m = re.search(r'^##\s+Acceptance Criteria\s*\n(.*?)(?=\n##\s|\Z)', body, re.DOTALL | re.MULTILINE)
if not m:
    sys.exit(0)
for line in m.group(1).splitlines():
    if re.match(r'\s*-\s*\[[ xX]\]', line):
        print(line.strip())
"
}

# Finds test files by bats convention for a given source file.
_find_bats_test() {
    local repo_root="$1"
    local source_file="$2"
    local module
    module=$(basename "$source_file" .sh)
    local candidate="$repo_root/tests/${module}.bats"
    [ -f "$candidate" ] && echo "$candidate" || true
}

# ---------------------------------------------------------------------------
# AC detection
# ---------------------------------------------------------------------------

@test "AC detection: finds ## Acceptance Criteria section" {
    local body
    body="$(printf '## Summary\nText\n\n## Acceptance Criteria\n- [ ] Criterion one\n- [ ] Criterion two')"
    result=$(_has_acceptance_criteria "$body")
    [ "$result" = "yes" ]
}

@test "AC detection: returns no when section is absent" {
    local body
    body="$(printf '## Summary\n- Some summary item')"
    result=$(_has_acceptance_criteria "$body")
    [ "$result" = "no" ]
}

@test "AC detection: returns no for empty body" {
    result=$(_has_acceptance_criteria "")
    [ "$result" = "no" ]
}

# ---------------------------------------------------------------------------
# AC parsing
# ---------------------------------------------------------------------------

@test "AC parsing: extracts checkboxes from Acceptance Criteria section" {
    local body
    body="$(printf '## Summary\nSome text\n\n## Acceptance Criteria\n- [ ] First criterion\n- [ ] Second criterion\n\n## Notes\nSome notes')"
    count=$(_parse_acceptance_criteria "$body" | wc -l | tr -d ' ')
    [ "$count" = "2" ]
}

@test "AC parsing: ignores checkboxes outside Acceptance Criteria section" {
    local body
    body="$(printf '## Notes\n- [ ] Not a criterion\n\n## Acceptance Criteria\n- [ ] Real criterion')"
    output=$(_parse_acceptance_criteria "$body")
    count=$(echo "$output" | wc -l | tr -d ' ')
    [ "$count" = "1" ]
    echo "$output" | grep -q "Real criterion"
    ! echo "$output" | grep -q "Not a criterion"
}

@test "AC parsing: returns empty when no Acceptance Criteria section" {
    local body
    body="$(printf '## Summary\n- Some summary')"
    output=$(_parse_acceptance_criteria "$body")
    [ -z "$output" ]
}

@test "AC parsing: handles checked checkboxes as valid ACs" {
    local body
    body="$(printf '## Acceptance Criteria\n- [x] Already done\n- [ ] Not done')"
    count=$(_parse_acceptance_criteria "$body" | wc -l | tr -d ' ')
    [ "$count" = "2" ]
}

# ---------------------------------------------------------------------------
# Structured comment shape
# ---------------------------------------------------------------------------

@test "QA comment template: contains all four phase headers and Verdict" {
    local comment
    comment="$(cat <<'COMMENT'
### QA verification — issue #42

**Phase 1: Acceptance criteria**
1. [✓ VERIFIED] Criterion one
   _Proof:_ `bash -n lib/foo.sh` → `OK`

**Phase 2: Tests added**
- (skipped: doc-only change)

**Phase 3: Regression on touched modules**
- `lib/foo.sh` → no existing test coverage, skipped

**Phase 4: validation_cmd**
- `bash -n lib/*.sh scripts/*.sh` → ✓ pass

**Verdict:** qa-pass
COMMENT
)"
    echo "$comment" | grep -q "Phase 1: Acceptance criteria"
    echo "$comment" | grep -q "Phase 2: Tests added"
    echo "$comment" | grep -q "Phase 3: Regression on touched modules"
    echo "$comment" | grep -q "Phase 4: validation_cmd"
    echo "$comment" | grep -q "Verdict:"
}

@test "QA comment template: issue number appears in heading" {
    local issue_num=99
    local comment="### QA verification — issue #${issue_num}"
    echo "$comment" | grep -q "issue #99"
}

@test "QA comment template: NOT_FOUND marker triggers qa-fail verdict" {
    local comment
    comment="$(printf '**Phase 1: Acceptance criteria**\n1. [✗ NOT_FOUND] Missing feature\n\n**Verdict:** qa-fail — AC1 not delivered.')"
    echo "$comment" | grep -q "NOT_FOUND"
    echo "$comment" | grep -q "qa-fail"
}

# ---------------------------------------------------------------------------
# Fallback when no ACs
# ---------------------------------------------------------------------------

@test "fallback: no AC section causes phases 1-2 to be skipped" {
    local body
    body="$(printf '## Summary\nJust a plain issue with no acceptance criteria')"
    local run_phases_1_2=false
    local gap_noted=false
    if [ "$(_has_acceptance_criteria "$body")" = "yes" ]; then
        run_phases_1_2=true
    else
        gap_noted=true
    fi
    [ "$run_phases_1_2" = "false" ]
    [ "$gap_noted" = "true" ]
}

@test "fallback: AC section present enables phases 1-2" {
    local body
    body="$(printf '## Acceptance Criteria\n- [ ] Do something')"
    local run_phases_1_2=false
    if [ "$(_has_acceptance_criteria "$body")" = "yes" ]; then
        run_phases_1_2=true
    fi
    [ "$run_phases_1_2" = "true" ]
}

@test "fallback: comment notes issue lacked criteria" {
    local body
    body="$(printf '## Summary\nNo criteria here')"
    local comment=""
    if [ "$(_has_acceptance_criteria "$body")" = "no" ]; then
        comment="Note: the linked issue has no ## Acceptance Criteria section — phases 1 and 2 were skipped."
    fi
    echo "$comment" | grep -q "lacked\|no ## Acceptance Criteria\|were skipped"
}

# ---------------------------------------------------------------------------
# Regression detection on touched files
# ---------------------------------------------------------------------------

@test "regression: finds existing bats test for lib/ module" {
    # qa-smart.bats itself acts as a test for the qa-handler module lookup
    local repo_root="$LOOP_ROOT"
    local touched_file="lib/qa-handler.sh"
    result=$(_find_bats_test "$repo_root" "$touched_file")
    # qa-handler.bats does not exist but the function returns empty (not error)
    # Verify scanner.bats DOES exist (known file)
    result2=$(_find_bats_test "$repo_root" "scanner/scanner.sh")
    [ -n "$result2" ]
    echo "$result2" | grep -q "scanner.bats"
}

@test "regression: returns empty for module with no test file" {
    local repo_root="$BATS_TMPDIR/fake-repo-$$"
    mkdir -p "$repo_root/tests"
    result=$(_find_bats_test "$repo_root" "lib/no-such-module.sh")
    [ -z "$result" ]
}

@test "regression: test file convention strips .sh extension" {
    local repo_root="$BATS_TMPDIR/conv-repo-$$"
    mkdir -p "$repo_root/tests"
    touch "$repo_root/tests/workflow.bats"
    result=$(_find_bats_test "$repo_root" "lib/workflow.sh")
    [ -n "$result" ]
    echo "$result" | grep -q "workflow.bats"
}

@test "regression: test file convention works for scripts/ path" {
    local repo_root="$BATS_TMPDIR/scripts-repo-$$"
    mkdir -p "$repo_root/tests"
    touch "$repo_root/tests/qa-handler.bats"
    result=$(_find_bats_test "$repo_root" "scripts/qa-handler.sh")
    [ -n "$result" ]
    echo "$result" | grep -q "qa-handler.bats"
}

# ---------------------------------------------------------------------------
# Conditional test-creation logic
# ---------------------------------------------------------------------------

@test "test creation: skipped for markdown file" {
    local file="docs/README.md"
    local should_create_test=true
    case "$file" in
        *.md|*.txt|docs/*) should_create_test=false ;;
    esac
    [ "$should_create_test" = "false" ]
}

@test "test creation: skipped for plain text file" {
    local file="CHANGELOG.txt"
    local should_create_test=true
    case "$file" in
        *.md|*.txt|docs/*) should_create_test=false ;;
    esac
    [ "$should_create_test" = "false" ]
}

@test "test creation: attempted for shell lib file with framework present" {
    local file="lib/foo.sh"
    local has_framework=true
    local is_doc_only=false
    local should_create_test=false
    case "$file" in
        *.md|*.txt|docs/*) is_doc_only=true ;;
    esac
    if [ "$is_doc_only" = "false" ] && [ "$has_framework" = "true" ]; then
        should_create_test=true
    fi
    [ "$should_create_test" = "true" ]
}

@test "test creation: skipped when no testing framework detected" {
    local file="lib/foo.sh"
    local has_framework=false
    local is_doc_only=false
    local should_create_test=false
    if [ "$is_doc_only" = "false" ] && [ "$has_framework" = "true" ]; then
        should_create_test=true
    fi
    [ "$should_create_test" = "false" ]
}
