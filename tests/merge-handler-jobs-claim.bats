#!/usr/bin/env bats
# tests/merge-handler-jobs-claim.bats
#
# Unit tests for the jobs-table claim path in merge-handler.sh.
#
# Tests cover:
#   (1) Claim happy path — PR_NUM is set from claimed row's issue_or_pr
#   (2) Double-claim safety — two parallel invocations claim at most one row
#   (3) Complete on success — cleanup marks job completed when exit rc=0
#   (4) Fail on error — cleanup marks job failed and attempts were incremented
#   (5) Fallback — no pending job → PR_NUM from event payload preserved

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    if ! command -v sqlite3 >/dev/null 2>&1; then
        skip "sqlite3 not available"
    fi

    export LOOP_JOBS_DB="$BATS_TMPDIR/merge-jobs-$$.db"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # shellcheck source=../lib/jobs.sh
    source "$REPO_ROOT/lib/jobs.sh"
    jobs_init_schema

    LOG_FILE="$BATS_TMPDIR/merge-handler.log"
    log() { echo "[merge-handler-test] $*" >> "$LOG_FILE" 2>/dev/null || true; }
    loop_release_lock() { :; }
}

teardown() {
    rm -f "$LOOP_JOBS_DB" "$BATS_TMPDIR/merge-handler.log"
    rm -rf "$BATS_TMPDIR/logs"
    unset LOOP_JOBS_DB LOOP_LOG_DIR
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: replicate the claim block from merge-handler.sh
# ─────────────────────────────────────────────────────────────────────────────
_run_claim_block() {
    local slug="$1"
    local initial_pr_num="${2:-}"

    PR_NUM="$initial_pr_num"
    _JOBS_CLAIMED_ID=""

    jobs_init_schema 2>/dev/null || true
    local _candidate
    _candidate=$(jobs_claim "$slug" "merge" 2>/dev/null || true)
    if [ -n "$_candidate" ]; then
        _JOBS_CLAIMED_ID="$_candidate"
        local _jobs_pr
        _jobs_pr=$(sqlite3 "$(jobs_db_path)" \
            "SELECT issue_or_pr FROM jobs WHERE id=${_JOBS_CLAIMED_ID};" 2>/dev/null || true)
        if [ -n "$_jobs_pr" ]; then
            PR_NUM="$_jobs_pr"
            log "claimed job id=${_JOBS_CLAIMED_ID} pr_num=${PR_NUM} from jobs table"
        fi
    fi
}

# Helper: replicate the cleanup logic from _merge_handler_cleanup
_run_cleanup() {
    local rc="$1"
    local claimed_id="$2"

    if [ -n "$claimed_id" ]; then
        if [ "$rc" -eq 0 ]; then
            jobs_complete "$claimed_id" || true
        else
            jobs_fail "$claimed_id" "handler exited rc=${rc}" || true
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# (1) Claim happy path
# ─────────────────────────────────────────────────────────────────────────────

@test "claim happy path: _JOBS_CLAIMED_ID is set when a pending job exists" {
    jobs_enqueue "test-proj" "merge" 42 >/dev/null

    _run_claim_block "test-proj" ""

    [ -n "$_JOBS_CLAIMED_ID" ]
}

@test "claim happy path: PR_NUM is set from row's issue_or_pr" {
    jobs_enqueue "test-proj" "merge" 42 >/dev/null

    _run_claim_block "test-proj" ""

    [ "$PR_NUM" = "42" ]
}

@test "claim happy path: row status transitions to in_flight after claim" {
    local id
    id=$(jobs_enqueue "test-proj" "merge" 42)

    _run_claim_block "test-proj" ""

    local status_val
    status_val=$(sqlite3 "$LOOP_JOBS_DB" "SELECT status FROM jobs WHERE id=${id};")
    [ "$status_val" = "in_flight" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (2) Double-claim safety
# ─────────────────────────────────────────────────────────────────────────────

@test "double-claim safety: two parallel invocations claim at most one row" {
    jobs_enqueue "test-proj" "merge" 99 >/dev/null

    local out1="$BATS_TMPDIR/claim1-$$.txt"
    local out2="$BATS_TMPDIR/claim2-$$.txt"

    (LOOP_JOBS_DB="$LOOP_JOBS_DB" jobs_claim "test-proj" "merge" "worker-1" > "$out1") &
    local pid1=$!
    (LOOP_JOBS_DB="$LOOP_JOBS_DB" jobs_claim "test-proj" "merge" "worker-2" > "$out2") &
    local pid2=$!

    wait "$pid1"
    wait "$pid2"

    local c1 c2 non_empty
    c1=$(cat "$out1")
    c2=$(cat "$out2")
    non_empty=0
    [ -n "$c1" ] && non_empty=$((non_empty + 1))
    [ -n "$c2" ] && non_empty=$((non_empty + 1))

    rm -f "$out1" "$out2"
    [ "$non_empty" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (3) Complete on success
# ─────────────────────────────────────────────────────────────────────────────

@test "complete-on-success: cleanup marks job completed when exit rc=0" {
    local id
    id=$(jobs_enqueue "test-proj" "merge" 55)
    jobs_claim "test-proj" "merge" >/dev/null

    _run_cleanup 0 "$id"

    local status_val
    status_val=$(sqlite3 "$LOOP_JOBS_DB" "SELECT status FROM jobs WHERE id=${id};")
    [ "$status_val" = "completed" ]
}

@test "complete-on-success: completed_at is recorded" {
    local id
    id=$(jobs_enqueue "test-proj" "merge" 55)
    jobs_claim "test-proj" "merge" >/dev/null

    _run_cleanup 0 "$id"

    local completed_at
    completed_at=$(sqlite3 "$LOOP_JOBS_DB" "SELECT completed_at FROM jobs WHERE id=${id};")
    [[ "$completed_at" =~ ^[0-9]+$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (4) Fail on error — attempts incremented at claim time, status becomes failed
# ─────────────────────────────────────────────────────────────────────────────

@test "fail-on-error: cleanup marks job failed when exit rc is non-zero" {
    local id
    id=$(jobs_enqueue "test-proj" "merge" 66)
    jobs_claim "test-proj" "merge" >/dev/null

    _run_cleanup 1 "$id"

    local status_val
    status_val=$(sqlite3 "$LOOP_JOBS_DB" "SELECT status FROM jobs WHERE id=${id};")
    [ "$status_val" = "failed" ]
}

@test "fail-on-error: attempts counter was incremented by claim" {
    local id
    id=$(jobs_enqueue "test-proj" "merge" 66)
    jobs_claim "test-proj" "merge" >/dev/null

    _run_cleanup 1 "$id"

    local attempts_val
    attempts_val=$(sqlite3 "$LOOP_JOBS_DB" "SELECT attempts FROM jobs WHERE id=${id};")
    [ "$attempts_val" -eq 1 ]
}

@test "fail-on-error: last_error is recorded with exit code detail" {
    local id
    id=$(jobs_enqueue "test-proj" "merge" 66)
    jobs_claim "test-proj" "merge" >/dev/null

    _run_cleanup 1 "$id"

    local last_error
    last_error=$(sqlite3 "$LOOP_JOBS_DB" "SELECT last_error FROM jobs WHERE id=${id};")
    [[ "$last_error" == *"rc=1"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (5) Fallback — no job in DB → legacy event-payload PR_NUM preserved
# ─────────────────────────────────────────────────────────────────────────────

@test "fallback: no pending job → _JOBS_CLAIMED_ID stays empty" {
    _run_claim_block "test-proj" "77"

    [ -z "$_JOBS_CLAIMED_ID" ]
}

@test "fallback: no pending job → PR_NUM from event payload is preserved" {
    _run_claim_block "test-proj" "77"

    [ "$PR_NUM" = "77" ]
}
