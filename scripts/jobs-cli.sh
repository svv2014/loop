#!/usr/bin/env bash
# scripts/jobs-cli.sh — CLI for inspecting the Loop jobs queue.
#
# Usage:
#   jobs-cli.sh list [--status STATUS] [--project SLUG] [--json] [--limit N]
#   jobs-cli.sh show <id> [--json]
#
# Invocation: ./scripts/jobs-cli.sh <subcommand> [flags]
# See README.md "Jobs CLI" section for full documentation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/jobs.sh
source "$LOOP_ROOT/lib/jobs.sh"

_usage() {
    cat >&2 <<'EOF'
Usage:
  jobs-cli.sh list [--status STATUS] [--project SLUG] [--json] [--limit N]
  jobs-cli.sh show <id> [--json]

Subcommands:
  list    Print all jobs (default) or filter by status/project
  show    Print a single job by id

Flags (list):
  --status STATUS    Filter: pending|in_flight|completed|failed
  --project SLUG     Filter by project slug
  --json             Emit JSON array matching the stable contract
  --limit N          Max rows to return (default: 100)

Flags (show):
  --json             Emit a single JSON object matching the stable contract
EOF
    exit 1
}

cmd_list() {
    local project="" status="" json=0 limit=100

    while [ $# -gt 0 ]; do
        case "$1" in
            --project)
                project="$2"; shift 2 ;;
            --status)
                case "$2" in
                    pending|in_flight|completed|failed)
                        status="$2"; shift 2 ;;
                    *)
                        echo "Error: unknown --status value '$2'. Valid: pending|in_flight|completed|failed" >&2
                        exit 1 ;;
                esac ;;
            --json)
                json=1; shift ;;
            --limit)
                limit="$2"; shift 2 ;;
            *)
                echo "Error: unknown flag '$1'" >&2
                _usage ;;
        esac
    done

    # Ensure schema exists before querying
    jobs_init_schema

    local db
    db=$(jobs_db_path)

    if [ "$json" -eq 1 ]; then
        _JOBS_DB="$db" _JOBS_PROJECT="$project" _JOBS_STATUS="$status" \
            _JOBS_LIMIT="$limit" python3 - <<'PY'
import json, os, sqlite3

db_path  = os.environ["_JOBS_DB"]
project  = os.environ.get("_JOBS_PROJECT", "")
status   = os.environ.get("_JOBS_STATUS", "")
limit    = int(os.environ.get("_JOBS_LIMIT", "100"))

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row

where_parts = []
params = []
if project:
    where_parts.append("project = ?")
    params.append(project)
if status:
    where_parts.append("status = ?")
    params.append(status)

where = ("WHERE " + " AND ".join(where_parts)) if where_parts else ""
sql = (
    "SELECT id, project, stage, issue_or_pr, status, claimed_by, "
    "claimed_at, completed_at, attempts, last_error, created_at "
    "FROM jobs " + where + " ORDER BY id LIMIT ?"
)
params.append(limit)

rows = conn.execute(sql, params).fetchall()
result = [dict(r) for r in rows]
print(json.dumps(result))
conn.close()
PY
    else
        _JOBS_DB="$db" _JOBS_PROJECT="$project" _JOBS_STATUS="$status" \
            _JOBS_LIMIT="$limit" python3 - <<'PY'
import os, sqlite3, sys

db_path  = os.environ["_JOBS_DB"]
project  = os.environ.get("_JOBS_PROJECT", "")
status   = os.environ.get("_JOBS_STATUS", "")
limit    = int(os.environ.get("_JOBS_LIMIT", "100"))

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row

where_parts = []
params = []
if project:
    where_parts.append("project = ?")
    params.append(project)
if status:
    where_parts.append("status = ?")
    params.append(status)

where = ("WHERE " + " AND ".join(where_parts)) if where_parts else ""
sql = (
    "SELECT id, project, stage, issue_or_pr, status, claimed_by, "
    "attempts, created_at "
    "FROM jobs " + where + " ORDER BY id LIMIT ?"
)
params.append(limit)

rows = conn.execute(sql, params).fetchall()
conn.close()

if not rows:
    print("No jobs found.")
    sys.exit(0)

headers = ["id", "project", "stage", "issue_or_pr", "status", "claimed_by", "attempts", "created_at"]
data = [[str(r[h]) if r[h] is not None else "" for h in headers] for r in rows]
widths = [max(len(h), max((len(row[i]) for row in data), default=0)) for i, h in enumerate(headers)]
sep = "  "
fmt_parts = ["{{:<{}}}".format(w) for w in widths]
fmt = sep.join(fmt_parts)
print(fmt.format(*headers))
print(sep.join("-" * w for w in widths))
for row in data:
    print(fmt.format(*row))
PY
    fi
}

cmd_show() {
    local id="" json=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)
                json=1; shift ;;
            [0-9]*)
                id="$1"; shift ;;
            *)
                echo "Error: unknown argument '$1'" >&2
                _usage ;;
        esac
    done

    if [ -z "$id" ]; then
        echo "Error: 'show' requires a job id" >&2
        _usage
    fi

    # Ensure schema exists before querying
    jobs_init_schema

    local db
    db=$(jobs_db_path)

    if [ "$json" -eq 1 ]; then
        _JOBS_DB="$db" _JOBS_ID="$id" python3 - <<'PY'
import json, os, sqlite3, sys

db_path = os.environ["_JOBS_DB"]
job_id  = int(os.environ["_JOBS_ID"])

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
row = conn.execute(
    "SELECT id, project, stage, issue_or_pr, status, claimed_by, "
    "claimed_at, completed_at, attempts, last_error, created_at "
    "FROM jobs WHERE id = ?",
    (job_id,)
).fetchone()
conn.close()

if row is None:
    print("Error: no job with id {}".format(job_id), file=sys.stderr)
    sys.exit(1)

print(json.dumps(dict(row)))
PY
    else
        _JOBS_DB="$db" _JOBS_ID="$id" python3 - <<'PY'
import os, sqlite3, sys

db_path = os.environ["_JOBS_DB"]
job_id  = int(os.environ["_JOBS_ID"])

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
row = conn.execute(
    "SELECT id, project, stage, issue_or_pr, status, claimed_by, "
    "claimed_at, completed_at, attempts, last_error, created_at "
    "FROM jobs WHERE id = ?",
    (job_id,)
).fetchone()
conn.close()

if row is None:
    print("Error: no job with id {}".format(job_id), file=sys.stderr)
    sys.exit(1)

for key in row.keys():
    val = row[key]
    print("{:<16} {}".format(key, val if val is not None else ""))
PY
    fi
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || _usage
shift

case "$SUBCOMMAND" in
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    *)
        echo "Error: unknown subcommand '$SUBCOMMAND'" >&2
        _usage ;;
esac
