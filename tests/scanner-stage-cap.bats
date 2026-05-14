#!/usr/bin/env bats
# tests/scanner-stage-cap.bats — unit tests for _stage_cap in scanner/scanner.sh.
# Added by QA for PR #366 (per-stage scanner emit caps).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    export LOOP_EXTRA_PATH=""
    local _src="$BATS_TMPDIR/scanner-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        awk '
            /^SCRIPT_DIR=/           { next }
            /^LOOP_ROOT=/            { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=false"; print "ONCE=false"; next }
            skip && /^done$/         { skip=0; next }
            skip                     { next }
            /^acquire_lock$/         { exit }
            { print }
        ' "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    DEDUP_DIR="$BATS_TMPDIR/dedup"
    LOG_FILE="$BATS_TMPDIR/scanner-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""
    log() { :; }
    dispatch_direct() { :; }
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-test.log" \
           "$BATS_TMPDIR/scanner-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _stage_cap — AC1, AC2, AC3
# ---------------------------------------------------------------------------

@test "_stage_cap: returns 1 when no env vars set" {
    unset MAX_CONCURRENT_HANDLERS MAX_CONCURRENT_HANDLERS_LOOP_DEV_ISSUE
    run _stage_cap "loop.dev_issue"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "_stage_cap: returns MAX_CONCURRENT_HANDLERS when no stage-specific var set" {
    unset MAX_CONCURRENT_HANDLERS_LOOP_DEV_ISSUE
    MAX_CONCURRENT_HANDLERS=4
    run _stage_cap "loop.dev_issue"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "_stage_cap: stage-specific var takes priority over global" {
    MAX_CONCURRENT_HANDLERS=4
    MAX_CONCURRENT_HANDLERS_LOOP_PR_REVIEW=7
    run _stage_cap "loop.pr_review"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

@test "_stage_cap: stage-specific var used even when global is unset" {
    unset MAX_CONCURRENT_HANDLERS
    MAX_CONCURRENT_HANDLERS_LOOP_PR_QA=3
    run _stage_cap "loop.pr_qa"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "_stage_cap: loop.po_review maps to MAX_CONCURRENT_HANDLERS_LOOP_PO_REVIEW" {
    unset MAX_CONCURRENT_HANDLERS
    MAX_CONCURRENT_HANDLERS_LOOP_PO_REVIEW=2
    run _stage_cap "loop.po_review"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "_stage_cap: loop.dev_rework maps to MAX_CONCURRENT_HANDLERS_LOOP_DEV_REWORK" {
    unset MAX_CONCURRENT_HANDLERS
    MAX_CONCURRENT_HANDLERS_LOOP_DEV_REWORK=1
    run _stage_cap "loop.dev_rework"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "_stage_cap: loop.pr_merge maps to MAX_CONCURRENT_HANDLERS_LOOP_PR_MERGE" {
    unset MAX_CONCURRENT_HANDLERS
    MAX_CONCURRENT_HANDLERS_LOOP_PR_MERGE=5
    run _stage_cap "loop.pr_merge"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "_stage_cap: stage-specific var does not bleed to sibling stage" {
    unset MAX_CONCURRENT_HANDLERS
    MAX_CONCURRENT_HANDLERS_LOOP_PR_REVIEW=9
    unset MAX_CONCURRENT_HANDLERS_LOOP_PR_QA
    run _stage_cap "loop.pr_qa"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}
