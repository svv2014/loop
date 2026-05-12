#!/usr/bin/env bats
# tests/dev-rework-handler-rebase-conflict.bats
# Regression tests for post-agent DIRTY escalation in dev-rework-handler.
#
# Covers the block added near the agent-run section: after the agent runs,
# if REBASE_CONFLICTS was set pre-agent and the rebase still cannot apply
# cleanly, the PR is labeled `blocked`, a comment is posted, and
# bounty_report "rework_blocked" is emitted.

setup() {
    OPS_LOG="$BATS_TMPDIR/label-ops.log"
    COMMENT_LOG="$BATS_TMPDIR/comment.log"
    BOUNTY_LOG="$BATS_TMPDIR/bounty.log"
    PUSH_LOG="$BATS_TMPDIR/push.log"
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$BOUNTY_LOG" "$PUSH_LOG"

    export REPO="owner/test-repo"
    export PR_NUM="42"
    export SLUG="test-proj"
    export DEFAULT_BRANCH="main"
    export PR_BRANCH="fix/issue-42-slug"
    export LOG_FILE="$BATS_TMPDIR/handler.log"
    export LOOP_AGENT_MODEL="sonnet"
    export LINKED_ISSUE="99"
    export WORKTREE_ROOT="$BATS_TMPDIR/fake-worktree"

    # Stub backend label functions
    backend_remove_label() { echo "remove $3" >> "$OPS_LOG"; }
    backend_add_label()    { echo "add $3"    >> "$OPS_LOG"; }

    # Stub bounty_report
    bounty_report() { echo "bounty_report $*" >> "$BOUNTY_LOG"; }

    # Stub loop_notify (no-op)
    loop_notify() { true; }

    # Stub cleanup_worktree (no-op)
    cleanup_worktree() { true; }
}

teardown() {
    rm -f "$OPS_LOG" "$COMMENT_LOG" "$BOUNTY_LOG" "$PUSH_LOG" \
          "$BATS_TMPDIR/handler.log"
}

# ---------------------------------------------------------------------------
# Helper: run the post-agent dirty check block as inlined from the handler.
# Returns 1 if escalated (PR was still DIRTY), 0 if clean.
# ---------------------------------------------------------------------------
_run_post_agent_block() {
    local post_dirty=false
    local post_agent_conflicts=""

    if [ -n "$REBASE_CONFLICTS" ]; then
        git -C "$WORKTREE_ROOT" fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
        if ! git -C "$WORKTREE_ROOT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
            post_dirty=true
            post_agent_conflicts=$(git -C "$WORKTREE_ROOT" diff --name-only --diff-filter=U 2>/dev/null \
                | tr '\n' ' ')
            post_agent_conflicts="${post_agent_conflicts% }"
            git -C "$WORKTREE_ROOT" rebase --abort 2>/dev/null || true
        else
            git -C "$WORKTREE_ROOT" push --force-with-lease origin "$PR_BRANCH" \
                2>/dev/null >> "$PUSH_LOG" || true
        fi
    fi

    if [ "$post_dirty" = "true" ]; then
        backend_remove_label "$REPO" "$PR_NUM" in-rework 2>/dev/null || true
        backend_add_label "$REPO" "$PR_NUM" blocked 2>/dev/null || true
        local block_marker="<!-- loop:rework_blocked -->"
        local already_blocked
        already_blocked=$(gh pr view "$PR_NUM" --repo "$REPO" --json comments \
            --jq "[.comments[] | select(.body | contains(\"${block_marker}\"))] | length" \
            2>/dev/null || echo "0")
        if [ "${already_blocked:-0}" = "0" ]; then
            local conflict_display
            conflict_display=$(echo "${post_agent_conflicts:-(unknown)}" | tr ' ' '\n')
            local block_body
            block_body=$(printf '%s\n%s\n\n```\n%s\n```' \
                "$block_marker" \
                "Rework blocked: rebase conflict unresolved after agent attempt." \
                "$conflict_display")
            if [ -n "$LINKED_ISSUE" ]; then
                block_body=$(printf '%s\nParent: #%s' "$block_body" "$LINKED_ISSUE")
            fi
            gh pr comment "$PR_NUM" --repo "$REPO" --body "$block_body" 2>/dev/null || true
        fi
        bounty_report "rework_blocked" model="${LOOP_AGENT_MODEL:-sonnet}" role=dev project="$SLUG" \
            pr_num="$PR_NUM" detail="rebase-conflict files=${post_agent_conflicts}" || true
        loop_notify "blocked"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Test 1: still DIRTY after agent — blocked label applied
# ---------------------------------------------------------------------------

@test "post-agent DIRTY: blocked label applied, in-rework removed" {
    export REBASE_CONFLICTS="src/main.go"

    git() {
        case "$*" in
            *"fetch"*)           return 0 ;;
            *"rebase --abort"*)  return 0 ;;
            *"rebase"*)          return 1 ;;  # still conflicts
            *"diff"*)            echo "src/main.go" ;;
            *"push"*)            echo "push" >> "$PUSH_LOG"; return 0 ;;
            *)                   return 0 ;;
        esac
    }
    gh() {
        case "$*" in
            *"json comments"*) echo "0" ;;
            *"pr comment"*)    echo "comment: $*" >> "$COMMENT_LOG" ;;
            *)                 true ;;
        esac
    }

    run _run_post_agent_block
    [ "$status" -eq 1 ]

    grep -q "remove in-rework" "$OPS_LOG"
    grep -q "add blocked"      "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 2: still DIRTY — PR comment posted with conflict file list
# ---------------------------------------------------------------------------

@test "post-agent DIRTY: PR comment posted containing conflict file and parent issue" {
    export REBASE_CONFLICTS="lib/helpers.sh"

    git() {
        case "$*" in
            *"fetch"*)           return 0 ;;
            *"rebase --abort"*)  return 0 ;;
            *"rebase"*)          return 1 ;;
            *"diff"*)            echo "lib/helpers.sh" ;;
            *)                   return 0 ;;
        esac
    }
    gh() {
        case "$*" in
            *"json comments"*) echo "0" ;;
            *"pr comment"*)    printf '%s\n' "$@" >> "$COMMENT_LOG" ;;
            *)                 true ;;
        esac
    }

    _run_post_agent_block || true

    # Comment file must exist and contain the conflict file name
    grep -q "lib/helpers.sh" "$COMMENT_LOG"
    # Comment must reference parent issue
    grep -q "Parent: #99" "$COMMENT_LOG" || grep -q "#99" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Test 3: still DIRTY — bounty_report rework_blocked emitted
# ---------------------------------------------------------------------------

@test "post-agent DIRTY: bounty_report rework_blocked emitted" {
    export REBASE_CONFLICTS="api/server.go"

    git() {
        case "$*" in
            *"fetch"*)           return 0 ;;
            *"rebase --abort"*)  return 0 ;;
            *"rebase"*)          return 1 ;;
            *"diff"*)            echo "api/server.go" ;;
            *)                   return 0 ;;
        esac
    }
    gh() {
        case "$*" in
            *"json comments"*) echo "0" ;;
            *"pr comment"*)    echo "comment" >> "$COMMENT_LOG" ;;
            *)                 true ;;
        esac
    }

    _run_post_agent_block || true

    grep -q "bounty_report rework_blocked" "$BOUNTY_LOG"
    grep -q "rebase-conflict" "$BOUNTY_LOG"
}

# ---------------------------------------------------------------------------
# Test 4: idempotency — comment not posted twice if marker already present
# ---------------------------------------------------------------------------

@test "post-agent DIRTY: comment not posted when marker already present" {
    export REBASE_CONFLICTS="src/conflict.go"

    git() {
        case "$*" in
            *"fetch"*)           return 0 ;;
            *"rebase --abort"*)  return 0 ;;
            *"rebase"*)          return 1 ;;
            *"diff"*)            echo "src/conflict.go" ;;
            *)                   return 0 ;;
        esac
    }
    gh() {
        case "$*" in
            *"json comments"*) echo "1" ;;  # marker already present
            *"pr comment"*)    echo "comment" >> "$COMMENT_LOG" ;;
            *)                 true ;;
        esac
    }

    _run_post_agent_block || true

    # Comment should NOT have been posted again
    [ ! -f "$COMMENT_LOG" ] || ! grep -q "comment" "$COMMENT_LOG"
}

# ---------------------------------------------------------------------------
# Test 5: no REBASE_CONFLICTS — check skipped entirely, no blocked label
# ---------------------------------------------------------------------------

@test "no pre-agent conflicts: post-agent check skipped, blocked label not applied" {
    export REBASE_CONFLICTS=""

    git() { return 0; }
    gh()  { return 0; }

    run _run_post_agent_block
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || ! grep -q "add blocked" "$OPS_LOG"
}

# ---------------------------------------------------------------------------
# Test 6: REBASE_CONFLICTS set but post-agent rebase now clean — no escalation,
#         clean push attempted
# ---------------------------------------------------------------------------

@test "pre-agent conflicts resolved by agent: no escalation, push attempted" {
    export REBASE_CONFLICTS="was/conflicting.go"

    git() {
        case "$*" in
            *"fetch"*)  return 0 ;;
            *"rebase"*) return 0 ;;  # clean now
            *"push"*)   echo "pushed" >> "$PUSH_LOG"; return 0 ;;
            *)          return 0 ;;
        esac
    }
    gh() { return 0; }

    run _run_post_agent_block
    [ "$status" -eq 0 ]

    [ ! -f "$OPS_LOG" ] || ! grep -q "add blocked" "$OPS_LOG"
    grep -q "pushed" "$PUSH_LOG"
}
