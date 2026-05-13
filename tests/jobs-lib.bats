#!/usr/bin/env bats
# tests/jobs-lib.bats — unit tests for lib/jobs.sh
#
# Each test gets its own LOOP_JOBS_DB in a temp directory so there is no
# cross-test contamination.  The tests cover:
#   (a) init idempotency
#   (b) enqueue deduplication (pending/in_flight blocks re-enqueue)
#   (c) claim atomicity — parallel claims → exactly one winner
#   (d) complete / fail status transitions

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_JOBS_DB="$BATS_TMPDIR/jobs-$$.db"
    # shellcheck source=../lib/jobs.sh
    source "$REPO_ROOT/lib/jobs.sh"
    jobs_init_schema
}

teardown() {
    rm -f "$LOOP_JOBS_DB"
    unset LOOP_JOBS_DB
}

# ─────────────────────────────────────────────────────────────────────────────
# (a) Init idempotency
# ─────────────────────────────────────────────────────────────────────────────

@test "jobs_init_schema is idempotent — calling twice produces no error" {
    # First call already happened in setup; a second call must succeed cleanly.
    run jobs_init_schema
    [ "$status" -eq 0 ]
}

@test "jobs_init_schema creates the jobs table" {
    local result
    result=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='jobs';")
    [ "$result" = "jobs" ]
}

@test "jobs_init_schema creates the partial unique index" {
    local result
    result=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT name FROM sqlite_master WHERE type='index' AND name='jobs_active_uniq';")
    [ "$result" = "jobs_active_uniq" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (b) Enqueue deduplication
# ─────────────────────────────────────────────────────────────────────────────

@test "jobs_enqueue returns an id on first insert" {
    run jobs_enqueue "proj" "dev" 1
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "jobs_enqueue returns the existing id when row is still pending (idempotent)" {
    local id1 id2
    id1=$(jobs_enqueue "proj" "dev" 10)
    id2=$(jobs_enqueue "proj" "dev" 10)
    [ "$id1" = "$id2" ]
}

@test "jobs_enqueue returns the existing id when row is in_flight (idempotent)" {
    local id1
    id1=$(jobs_enqueue "proj" "dev" 11)
    # Claim it so it becomes in_flight
    jobs_claim "proj" "dev" >/dev/null

    local id2
    id2=$(jobs_enqueue "proj" "dev" 11)
    [ "$id1" = "$id2" ]
}

@test "jobs_enqueue allows re-enqueue after completed" {
    local id1
    id1=$(jobs_enqueue "proj" "dev" 20)
    jobs_claim "proj" "dev" >/dev/null
    jobs_complete "$id1"

    local id2
    id2=$(jobs_enqueue "proj" "dev" 20)
    # A new row is inserted — ids differ
    [ "$id1" != "$id2" ]
    [[ "$id2" =~ ^[0-9]+$ ]]
}

@test "jobs_enqueue allows re-enqueue after failed" {
    local id1
    id1=$(jobs_enqueue "proj" "dev" 30)
    jobs_claim "proj" "dev" >/dev/null
    jobs_fail "$id1" "something broke"

    local id2
    id2=$(jobs_enqueue "proj" "dev" 30)
    [ "$id1" != "$id2" ]
    [[ "$id2" =~ ^[0-9]+$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (c) Claim atomicity — two parallel claims → exactly one winner
# ─────────────────────────────────────────────────────────────────────────────

@test "parallel jobs_claim — exactly one caller obtains the id" {
    jobs_enqueue "proj" "dev" 99 >/dev/null

    local out1="$BATS_TMPDIR/claim1-$$.txt"
    local out2="$BATS_TMPDIR/claim2-$$.txt"

    # Fire two concurrent claims; the LOOP_JOBS_DB env var is inherited.
    (jobs_claim "proj" "dev" "worker-1" > "$out1") &
    local pid1=$!
    (jobs_claim "proj" "dev" "worker-2" > "$out2") &
    local pid2=$!

    wait "$pid1"
    wait "$pid2"

    local c1 c2
    c1=$(cat "$out1")
    c2=$(cat "$out2")

    # Exactly one of the two outputs must be non-empty (the winner).
    local non_empty=0
    [ -n "$c1" ] && non_empty=$((non_empty + 1))
    [ -n "$c2" ] && non_empty=$((non_empty + 1))

    rm -f "$out1" "$out2"
    [ "$non_empty" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (d) Complete / fail status transitions
# ─────────────────────────────────────────────────────────────────────────────

@test "jobs_complete sets status to completed and records completed_at" {
    local id
    id=$(jobs_enqueue "proj" "stage" 50)
    jobs_claim "proj" "stage" >/dev/null
    jobs_complete "$id"

    local status_val completed_at
    status_val=$(sqlite3 "$LOOP_JOBS_DB" "SELECT status FROM jobs WHERE id=${id};")
    completed_at=$(sqlite3 "$LOOP_JOBS_DB" "SELECT completed_at FROM jobs WHERE id=${id};")

    [ "$status_val" = "completed" ]
    [[ "$completed_at" =~ ^[0-9]+$ ]]
}

@test "jobs_fail sets status to failed and records last_error and completed_at" {
    local id
    id=$(jobs_enqueue "proj" "stage" 60)
    jobs_claim "proj" "stage" >/dev/null
    jobs_fail "$id" "timeout after 30s"

    local status_val last_error completed_at
    status_val=$(sqlite3 "$LOOP_JOBS_DB" "SELECT status FROM jobs WHERE id=${id};")
    last_error=$(sqlite3 "$LOOP_JOBS_DB" "SELECT last_error FROM jobs WHERE id=${id};")
    completed_at=$(sqlite3 "$LOOP_JOBS_DB" "SELECT completed_at FROM jobs WHERE id=${id};")

    [ "$status_val" = "failed" ]
    [ "$last_error" = "timeout after 30s" ]
    [[ "$completed_at" =~ ^[0-9]+$ ]]
}

@test "jobs_list returns all rows when called with no filters" {
    jobs_enqueue "p1" "dev" 1 >/dev/null
    jobs_enqueue "p2" "qa"  2 >/dev/null

    run jobs_list
    [ "$status" -eq 0 ]
    # Expect two lines
    [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "jobs_list filters by project" {
    jobs_enqueue "alpha" "dev" 1 >/dev/null
    jobs_enqueue "beta"  "dev" 2 >/dev/null

    run jobs_list "alpha"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
    [[ "$output" == *"alpha"* ]]
}

@test "jobs_claim increments attempts counter" {
    local id
    id=$(jobs_enqueue "proj" "dev" 70)

    local before after
    before=$(sqlite3 "$LOOP_JOBS_DB" "SELECT attempts FROM jobs WHERE id=${id};")
    jobs_claim "proj" "dev" >/dev/null
    after=$(sqlite3 "$LOOP_JOBS_DB" "SELECT attempts FROM jobs WHERE id=${id};")

    [ "$before" -eq 0 ]
    [ "$after" -eq 1 ]
}
