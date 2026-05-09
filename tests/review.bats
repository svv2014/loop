#!/usr/bin/env bats
# tests/review.bats — unit tests for draft PR detection in review-handler and qa-handler.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_WORKFLOW_DIR="$REPO_ROOT/config/workflows"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"

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
    export LOOP_CONFIG="$BATS_TMPDIR/fixture.yaml"
}

teardown() {
    rm -f "$BATS_TMPDIR/fixture.yaml" \
          "$BATS_TMPDIR/label-ops.log" \
          "$BATS_TMPDIR/comment-ops.log"
}

# ---------------------------------------------------------------------------
# review-handler draft detection
# ---------------------------------------------------------------------------

@test "review-handler draft: isDraft=true → removes review labels, adds draft, posts comment, exits 0" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    local comment_log="$BATS_TMPDIR/comment-ops.log"
    rm -f "$ops_log" "$comment_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }
    backend_comment_pr()   { echo "comment: $3" >> "$comment_log"; }
    gh() {
        case "$*" in
            *isDraft*) echo "true" ;;
            *) true ;;
        esac
    }

    # Replicate draft-check block from review-handler.sh
    local REPO="owner/test-repo"
    local PR_NUM="42"
    _is_draft=$(gh pr view "$PR_NUM" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")

    local _exit_code=1
    if [ "$_is_draft" = "true" ]; then
        gh label create draft --color "#808080" --description "PR is in Draft state" --repo "$REPO" 2>/dev/null || true
        backend_remove_label "$REPO" "$PR_NUM" needs-review
        backend_remove_label "$REPO" "$PR_NUM" review-pending
        backend_add_label    "$REPO" "$PR_NUM" draft
        backend_comment_pr   "$REPO" "$PR_NUM" "PR is in Draft state — review skipped. When ready: mark the PR ready for review on GitHub, remove the \`draft\` label, and re-apply \`needs-review\` to re-enter the pipeline."
        _exit_code=0
    fi

    [ "$_exit_code" -eq 0 ]
    grep -q "remove needs-review"   "$ops_log"
    grep -q "remove review-pending" "$ops_log"
    grep -q "add draft"             "$ops_log"
    ! grep -q "add needs-review"    "$ops_log"
    grep -q "re-apply"              "$comment_log"
    ! grep -q "automatically"       "$comment_log"
}

@test "review-handler draft: isDraft=false → draft path not taken, draft label not added" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }
    gh() { echo "false"; }

    local REPO="owner/test-repo"
    local PR_NUM="42"
    _is_draft=$(gh pr view "$PR_NUM" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")

    local _draft_path_taken=false
    if [ "$_is_draft" = "true" ]; then
        _draft_path_taken=true
        backend_add_label "$REPO" "$PR_NUM" draft
    fi

    [ "$_draft_path_taken" = "false" ]
    [ ! -f "$ops_log" ] || ! grep -q "add draft" "$ops_log"
}

# ---------------------------------------------------------------------------
# qa-handler draft detection
# ---------------------------------------------------------------------------

@test "qa-handler draft: isDraft=true → removes qa labels, adds draft, posts comment, exits 0" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    local comment_log="$BATS_TMPDIR/comment-ops.log"
    rm -f "$ops_log" "$comment_log"

    backend_remove_label() { echo "remove $3" >> "$ops_log"; }
    backend_add_label()    { echo "add $3"    >> "$ops_log"; }
    backend_comment_pr()   { echo "comment: $3" >> "$comment_log"; }
    gh() {
        case "$*" in
            *isDraft*) echo "true" ;;
            *) true ;;
        esac
    }

    local REPO="owner/test-repo"
    local PR_NUM="42"
    _is_draft=$(gh pr view "$PR_NUM" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")

    local _exit_code=1
    if [ "$_is_draft" = "true" ]; then
        gh label create draft --color "#808080" --description "PR is in Draft state" --repo "$REPO" 2>/dev/null || true
        backend_remove_label "$REPO" "$PR_NUM" needs-qa
        backend_remove_label "$REPO" "$PR_NUM" ready-for-qa
        backend_add_label    "$REPO" "$PR_NUM" draft
        backend_comment_pr   "$REPO" "$PR_NUM" "PR is in Draft state — review skipped. When ready: mark the PR ready for review on GitHub, remove the \`draft\` label, and re-apply \`needs-review\` to re-enter the pipeline."
        _exit_code=0
    fi

    [ "$_exit_code" -eq 0 ]
    grep -q "remove needs-qa"      "$ops_log"
    grep -q "remove ready-for-qa"  "$ops_log"
    grep -q "add draft"            "$ops_log"
    ! grep -q "add needs-qa"       "$ops_log"
    grep -q "re-apply"             "$comment_log"
    ! grep -q "automatically"      "$comment_log"
}

# ---------------------------------------------------------------------------
# review-handler deterministic decision sync (issue #260)
# ---------------------------------------------------------------------------

@test "review decision CHANGES_REQUESTED: needs-rework added, in-review removed" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label()      { echo "remove $3" >> "$ops_log"; }
    backend_add_label()         { echo "add $3"    >> "$ops_log"; }
    backend_pr_has_any_label()  { return 1; }  # no decision label yet
    backend_pr_view()           { echo "CHANGES_REQUESTED"; }

    local REPO="owner/test-repo"
    local PR_NUM="99"
    local _REWORK_LABEL="needs-rework"
    local LOOP_LABEL_DEPRECATED_NEEDS_REWORK="needs-rework"
    local LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED="changes-requested"
    local LOOP_LABEL_NEEDS_QA="needs-qa"
    local LOOP_LABEL_DEPRECATED_READY_FOR_QA="ready-for-qa"

    _decision=$(backend_pr_view "$REPO" "$PR_NUM" --json reviewDecision --jq .reviewDecision 2>/dev/null || echo "")
    [ "$_decision" = "null" ] && _decision=""

    case "$_decision" in
        CHANGES_REQUESTED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$_REWORK_LABEL"
            ;;
        APPROVED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
        *)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
    esac

    grep -q "remove in-review"    "$ops_log"
    grep -q "add needs-rework"    "$ops_log"
    ! grep -q "add needs-qa"      "$ops_log"
}

@test "review decision APPROVED: no rework label applied" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label()      { echo "remove $3" >> "$ops_log"; }
    backend_add_label()         { echo "add $3"    >> "$ops_log"; }
    backend_pr_view()           { echo "APPROVED"; }

    local REPO="owner/test-repo"
    local PR_NUM="99"
    local _REWORK_LABEL="needs-rework"
    local LOOP_LABEL_DEPRECATED_NEEDS_REWORK="needs-rework"
    local LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED="changes-requested"

    _decision=$(backend_pr_view "$REPO" "$PR_NUM" --json reviewDecision --jq .reviewDecision 2>/dev/null || echo "")
    [ "$_decision" = "null" ] && _decision=""

    case "$_decision" in
        CHANGES_REQUESTED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$_REWORK_LABEL"
            ;;
        APPROVED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
        *)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
    esac

    grep -q "remove in-review"    "$ops_log"
    ! grep -q "add needs-rework"  "$ops_log"
}

@test "review decision empty: belt-and-braces default applies needs-rework" {
    local ops_log="$BATS_TMPDIR/label-ops.log"
    rm -f "$ops_log"

    backend_remove_label()      { echo "remove $3" >> "$ops_log"; }
    backend_add_label()         { echo "add $3"    >> "$ops_log"; }
    backend_pr_has_any_label()  { return 1; }  # no decision label present
    backend_pr_view()           { echo ""; }

    local REPO="owner/test-repo"
    local PR_NUM="99"
    local _REWORK_LABEL="needs-rework"
    local LOOP_LABEL_NEEDS_QA="needs-qa"
    local LOOP_LABEL_DEPRECATED_READY_FOR_QA="ready-for-qa"
    local LOOP_LABEL_DEPRECATED_NEEDS_REWORK="needs-rework"
    local LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED="changes-requested"

    _decision=$(backend_pr_view "$REPO" "$PR_NUM" --json reviewDecision --jq .reviewDecision 2>/dev/null || echo "")
    [ "$_decision" = "null" ] && _decision=""

    case "$_decision" in
        CHANGES_REQUESTED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" 2>/dev/null || true
            backend_add_label    "$REPO" "$PR_NUM" "$_REWORK_LABEL"
            ;;
        APPROVED)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
        *)
            backend_remove_label "$REPO" "$PR_NUM" in-review
            ;;
    esac

    # Belt-and-braces fires because no decision label is present.
    if ! backend_pr_has_any_label "$REPO" "$PR_NUM" \
            "$LOOP_LABEL_NEEDS_QA" "$LOOP_LABEL_DEPRECATED_READY_FOR_QA" \
            "$_REWORK_LABEL" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED" \
            blocked 'done'; then
        backend_remove_label "$REPO" "$PR_NUM" "$LOOP_LABEL_DEPRECATED_NEEDS_REWORK" "$LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED"
        backend_add_label    "$REPO" "$PR_NUM" "$_REWORK_LABEL"
    fi

    grep -q "remove in-review"   "$ops_log"
    grep -q "add needs-rework"   "$ops_log"
}
