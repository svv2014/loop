#!/usr/bin/env bats
# tests/jobs-cli.bats — integration tests for scripts/jobs-cli.sh
#
# Each test gets an isolated LOOP_JOBS_DB in a temp directory.
# Tests cover:
#   (a) unfiltered list shows all rows
#   (b) --status filtering
#   (c) --project filtering
#   (d) --json output: valid array, all contract keys present
#   (e) show <id> returns the row
#   (f) show <missing> exits non-zero
#   (g) unknown subcommand exits non-zero
#   (h) unknown --status value exits non-zero

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CLI="$REPO_ROOT/scripts/jobs-cli.sh"

setup() {
    export LOOP_JOBS_DB="$BATS_TMPDIR/jobs-cli-$$.db"
    export LOOP_LOG_DIR="$BATS_TMPDIR"
    # shellcheck source=../lib/jobs.sh
    source "$REPO_ROOT/lib/jobs.sh"
    jobs_init_schema

    # Seed one row of each status
    ID_PENDING=$(jobs_enqueue "alpha" "dev"    101)
    ID_IN_FLIGHT=$(jobs_enqueue "alpha" "review" 102)
    jobs_claim "alpha" "review" "worker-1" >/dev/null
    ID_COMPLETED=$(jobs_enqueue "beta"  "qa"    201)
    jobs_claim "beta" "qa" "worker-2" >/dev/null
    jobs_complete "$ID_COMPLETED"
    ID_FAILED=$(jobs_enqueue "beta"  "merge" 202)
    jobs_claim "beta" "merge" "worker-3" >/dev/null
    jobs_fail "$ID_FAILED" "something went wrong"

    export ID_PENDING ID_IN_FLIGHT ID_COMPLETED ID_FAILED
}

teardown() {
    rm -f "$LOOP_JOBS_DB"
    unset LOOP_JOBS_DB LOOP_LOG_DIR ID_PENDING ID_IN_FLIGHT ID_COMPLETED ID_FAILED
}

# ─────────────────────────────────────────────────────────────────────────────
# (a) Unfiltered list shows all rows
# ─────────────────────────────────────────────────────────────────────────────

@test "list with no filters shows all 4 rows" {
    run "$CLI" list
    [ "$status" -eq 0 ]
    # 4 data rows + header + separator = 6 lines
    [ "$(echo "$output" | wc -l | tr -d ' ')" -ge 6 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (b) --status filtering
# ─────────────────────────────────────────────────────────────────────────────

@test "list --status pending shows only the pending row" {
    run "$CLI" list --status pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending"* ]]
    [[ "$output" != *"in_flight"* ]]
    [[ "$output" != *"completed"* ]]
    [[ "$output" != *"failed"* ]]
}

@test "list --status in_flight shows only the in_flight row" {
    run "$CLI" list --status in_flight
    [ "$status" -eq 0 ]
    [[ "$output" == *"in_flight"* ]]
    [[ "$output" != *"pending"* ]]
}

@test "list --status completed shows only the completed row" {
    run "$CLI" list --status completed
    [ "$status" -eq 0 ]
    [[ "$output" == *"completed"* ]]
    [[ "$output" != *"failed"* ]]
}

@test "list --status failed shows only the failed row" {
    run "$CLI" list --status failed
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" != *"completed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (c) --project filtering
# ─────────────────────────────────────────────────────────────────────────────

@test "list --project alpha shows only alpha rows" {
    run "$CLI" list --project alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "list --project beta shows only beta rows" {
    run "$CLI" list --project beta
    [ "$status" -eq 0 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" != *"alpha"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (d) --json output: valid array, all contract keys present
# ─────────────────────────────────────────────────────────────────────────────

@test "list --json emits a valid JSON array" {
    run "$CLI" list --json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c "import json,sys; data=json.load(sys.stdin); assert isinstance(data, list)"
}

@test "list --json first element contains all contract keys" {
    run "$CLI" list --json --limit 1
    [ "$status" -eq 0 ]
    JSON_DATA="$output" python3 - <<'PY'
import json, os
data = json.loads(os.environ["JSON_DATA"])
assert len(data) >= 1, "expected at least one element"
required = {"id","project","stage","issue_or_pr","status","claimed_by",
            "claimed_at","completed_at","attempts","last_error","created_at"}
missing = required - set(data[0].keys())
assert not missing, "missing keys: {}".format(missing)
PY
}

@test "list --json integer fields are integers not strings" {
    run "$CLI" list --json --status pending
    [ "$status" -eq 0 ]
    JSON_DATA="$output" python3 - <<'PY'
import json, os
data = json.loads(os.environ["JSON_DATA"])
row = data[0]
assert isinstance(row["id"], int), "id must be int"
assert isinstance(row["issue_or_pr"], int), "issue_or_pr must be int"
assert isinstance(row["attempts"], int), "attempts must be int"
assert isinstance(row["created_at"], int), "created_at must be int"
PY
}

@test "list --json nullable fields use null not empty string" {
    run "$CLI" list --json --status pending
    [ "$status" -eq 0 ]
    JSON_DATA="$output" python3 - <<'PY'
import json, os
data = json.loads(os.environ["JSON_DATA"])
row = data[0]
# pending row has no claimed_by, claimed_at, completed_at, last_error
assert row["claimed_by"] is None, "claimed_by must be null for pending row"
assert row["claimed_at"] is None, "claimed_at must be null for pending row"
assert row["completed_at"] is None, "completed_at must be null for pending row"
assert row["last_error"] is None, "last_error must be null for pending row"
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# (e) show <id> returns the row
# ─────────────────────────────────────────────────────────────────────────────

@test "show <id> (table format) prints the job" {
    run "$CLI" show "$ID_PENDING"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"pending"* ]]
}

@test "show <id> --json emits a single JSON object with all contract keys" {
    run "$CLI" show "$ID_PENDING" --json
    [ "$status" -eq 0 ]
    JSON_DATA="$output" python3 - <<'PY'
import json, os
obj = json.loads(os.environ["JSON_DATA"])
assert isinstance(obj, dict), "expected a JSON object"
required = {"id","project","stage","issue_or_pr","status","claimed_by",
            "claimed_at","completed_at","attempts","last_error","created_at"}
missing = required - set(obj.keys())
assert not missing, "missing keys: {}".format(missing)
PY
}

@test "show completed job --json has non-null completed_at" {
    run "$CLI" show "$ID_COMPLETED" --json
    [ "$status" -eq 0 ]
    JSON_DATA="$output" python3 - <<'PY'
import json, os
obj = json.loads(os.environ["JSON_DATA"])
assert obj["status"] == "completed"
assert isinstance(obj["completed_at"], int), "completed_at must be an int"
PY
}

@test "show failed job --json has last_error populated" {
    run "$CLI" show "$ID_FAILED" --json
    [ "$status" -eq 0 ]
    JSON_DATA="$output" python3 - <<'PY'
import json, os
obj = json.loads(os.environ["JSON_DATA"])
assert obj["status"] == "failed"
assert obj["last_error"] == "something went wrong"
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# (f) show <missing> exits non-zero
# ─────────────────────────────────────────────────────────────────────────────

@test "show with a non-existent id exits non-zero" {
    run "$CLI" show 99999
    [ "$status" -ne 0 ]
}

@test "show with a non-existent id --json exits non-zero" {
    run "$CLI" show 99999 --json
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (g) Unknown subcommand exits non-zero
# ─────────────────────────────────────────────────────────────────────────────

@test "unknown subcommand exits non-zero" {
    run "$CLI" frobnicate
    [ "$status" -ne 0 ]
}

@test "no subcommand exits non-zero" {
    run "$CLI"
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (h) Unknown --status value exits non-zero
# ─────────────────────────────────────────────────────────────────────────────

@test "list --status with unknown value exits non-zero" {
    run "$CLI" list --status garbage
    [ "$status" -ne 0 ]
}
