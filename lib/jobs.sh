#!/usr/bin/env bash
# jobs.sh — SQLite-backed job queue primitives for Loop.
#
# Provides a single jobs table with a partial unique index that prevents
# double-enqueue of the same (project, stage, issue_or_pr) while a row is
# still pending or in_flight.  Once a job reaches completed/failed it can be
# re-enqueued (e.g. after rework).
#
# Design note — jobs_enqueue deduplication policy:
#   When a (project, stage, issue_or_pr) already has a pending/in_flight row,
#   jobs_enqueue silently no-ops and prints the existing id.  This is the
#   idempotent path: the scanner ticks frequently and will re-see the same
#   issue on every poll; treating the second enqueue as an error would be
#   noisy and unhelpful.
#
# Minimum SQLite version: 3.35.0 (RETURNING clause in jobs_claim).
# macOS 12+ ships 3.39+; Ubuntu 22.04 ships 3.37+.
#
# Usage:
#   source "$LOOP_ROOT/lib/jobs.sh"
#   jobs_init_schema
#   id=$(jobs_enqueue "myproject" "dev" 42)
#   claimed=$(jobs_claim "myproject" "dev")
#   jobs_complete "$claimed"

set -euo pipefail

# jobs_db_path — single authority for the DB file location.
# All other functions call this rather than computing the path themselves.
jobs_db_path() {
    echo "${LOOP_JOBS_DB:-${LOOP_LOG_DIR:-$HOME/.loop}/jobs.db}"
}

# jobs_init_schema — create table + index when absent; idempotent.
jobs_init_schema() {
    local db
    db=$(jobs_db_path)
    mkdir -p "$(dirname "$db")"
    sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS jobs (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    project       TEXT    NOT NULL,
    stage         TEXT    NOT NULL,
    issue_or_pr   INTEGER NOT NULL,
    claimed_by    TEXT,
    claimed_at    INTEGER,
    completed_at  INTEGER,
    status        TEXT    NOT NULL,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    created_at    INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS jobs_active_uniq
    ON jobs(project, stage, issue_or_pr)
    WHERE status IN ('pending','in_flight');
SQL
}

# jobs_enqueue <project> <stage> <issue_or_pr>
# Inserts a new pending job and prints its id.
# If an active (pending/in_flight) row already exists, prints its id and exits 0
# without inserting a duplicate (idempotent enqueue — see header note).
jobs_enqueue() {
    local project="$1"
    local stage="$2"
    local issue_or_pr="$3"
    local db
    db=$(jobs_db_path)

    local existing
    existing=$(sqlite3 "$db" \
        "SELECT id FROM jobs WHERE project='${project}' AND stage='${stage}' AND issue_or_pr=${issue_or_pr} AND status IN ('pending','in_flight') LIMIT 1;")
    if [ -n "$existing" ]; then
        echo "$existing"
        return 0
    fi

    sqlite3 "$db" <<SQL
INSERT INTO jobs(project, stage, issue_or_pr, status, created_at)
VALUES('${project}', '${stage}', ${issue_or_pr}, 'pending', strftime('%s','now'));
SELECT last_insert_rowid();
SQL
}

# jobs_claim <project> <stage> [claimed_by]
# Atomically claims the lowest-id pending job for (project, stage).
# Prints the claimed row id, or nothing if no candidate.
# Uses BEGIN IMMEDIATE so concurrent callers serialize at the SQLite write lock;
# exactly one obtains the row, the other sees no candidate.
jobs_claim() {
    local project="$1"
    local stage="$2"
    local claimer="${3:-$$}"
    local db
    db=$(jobs_db_path)

    sqlite3 "$db" <<SQL
.timeout 5000
BEGIN IMMEDIATE;
UPDATE jobs
   SET status='in_flight',
       claimed_by='${claimer}',
       claimed_at=strftime('%s','now'),
       attempts=attempts+1
 WHERE id = (
     SELECT id FROM jobs
      WHERE status='pending'
        AND project='${project}'
        AND stage='${stage}'
      ORDER BY id
      LIMIT 1
 )
 RETURNING id;
COMMIT;
SQL
}

# jobs_complete <id>
# Marks a job as completed and records the completion timestamp.
jobs_complete() {
    local id="$1"
    local db
    db=$(jobs_db_path)
    sqlite3 "$db" "UPDATE jobs SET status='completed', completed_at=strftime('%s','now') WHERE id=${id};"
}

# jobs_fail <id> <error_message>
# Marks a job as failed, records the error, and sets completed_at.
jobs_fail() {
    local id="$1"
    local error="${2:-}"
    local db
    db=$(jobs_db_path)
    # Escape single quotes in error message for SQLite
    local safe_error="${error//\'/\'\'}"
    sqlite3 "$db" "UPDATE jobs SET status='failed', last_error='${safe_error}', completed_at=strftime('%s','now') WHERE id=${id};"
}

# jobs_list [project] [stage] [status]
# Lists jobs, optionally filtered.  Tab-separated output: id|project|stage|issue_or_pr|status|attempts
jobs_list() {
    local project="${1:-}"
    local stage="${2:-}"
    local filter_status="${3:-}"
    local db
    db=$(jobs_db_path)

    local where=""
    if [ -n "$project" ] || [ -n "$stage" ] || [ -n "$filter_status" ]; then
        local sep="WHERE"
        [ -n "$project" ]       && where+=" ${sep} project='${project}'"       && sep="AND"
        [ -n "$stage" ]         && where+=" ${sep} stage='${stage}'"           && sep="AND"
        [ -n "$filter_status" ] && where+=" ${sep} status='${filter_status}'"
    fi

    sqlite3 "$db" "SELECT id, project, stage, issue_or_pr, status, attempts FROM jobs${where} ORDER BY id;"
}
