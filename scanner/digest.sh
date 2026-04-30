#!/usr/bin/env bash
# scanner/digest.sh — Daily operator digest of stuck items across all projects.
#
# Queries every project in config/projects.yaml for:
#   - Issues with labels: needs-clarification, blocked
#   - Issues with operational labels (in-progress, in-review, deprecated rework alias)
#     stuck longer than 2× HANDLER_TIMEOUT (genuine stuck, not mid-flight)
#
# Posts a single Markdown digest via loop_notify.
# Suppressed entirely when zero stuck items exist (no noise).
#
# Usage:
#   scanner/digest.sh              # run across all projects
#   scanner/digest.sh --dry-run    # print digest to stdout only, no notify

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/labels.sh
source "$LOOP_ROOT/lib/labels.sh"
# shellcheck source=../lib/notify.sh
source "$LOOP_ROOT/lib/notify.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-digest.log"
HANDLER_TIMEOUT="${LOOP_HANDLER_TIMEOUT:-7200}"
# Operational labels are "stuck" when older than 2× handler timeout
STUCK_THRESHOLD_SEC=$(( HANDLER_TIMEOUT * 2 ))

DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '1,15p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    printf '[%s] [digest] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Fetch open issues with a given label, return JSON array.
fetch_issues_with_label() {
    local repo="$1" label="$2"
    gh issue list --repo "$repo" --label "$label" \
        --state open --limit 200 \
        --json number,title,labels,updatedAt,createdAt 2>/dev/null || echo "[]"
}

# Fetch last comment body for an issue, truncated to 80 chars.
fetch_last_comment() {
    local repo="$1" number="$2"
    local body
    body=$(gh issue view "$number" --repo "$repo" \
        --json comments --jq '.comments[-1].body // ""' 2>/dev/null || echo "")
    # collapse whitespace and truncate
    body=$(printf '%s' "$body" | tr '\n\r' '  ' | sed 's/  */ /g')
    if [ ${#body} -gt 80 ]; then
        printf '%s…' "${body:0:79}"
    else
        printf '%s' "$body"
    fi
}

# Collect stuck items for one project.
# Outputs tab-separated: age_h <TAB> number <TAB> labels <TAB> title <TAB> comment
collect_project_items() {
    local repo="$1"

    # --- needs-clarification and blocked (always included) ---
    local nc_json blocked_json merged_json
    nc_json=$(fetch_issues_with_label "$repo" "needs-clarification")
    blocked_json=$(fetch_issues_with_label "$repo" "blocked")

    # --- operational labels stuck > 2× HANDLER_TIMEOUT ---
    local ip_json ir_json irw_json
    ip_json=$(fetch_issues_with_label "$repo"  "in-progress")
    ir_json=$(fetch_issues_with_label "$repo"  "in-review")
    irw_json=$(fetch_issues_with_label "$repo" "$LOOP_LABEL_DEPRECATED_IN_REWORK")

    # Merge, deduplicate, classify, and filter by age threshold for operational.
    merged_json=$(
        NC="$nc_json" BL="$blocked_json" \
        IP="$ip_json" IR="$ir_json" IRW="$irw_json" \
        STUCK_SEC="$STUCK_THRESHOLD_SEC" \
        python3 - <<'PY'
import json, os, datetime as dt

def load(var):
    return json.loads(os.environ.get(var, '[]') or '[]')

nc   = load('NC')
bl   = load('BL')
ip   = load('IP')
ir   = load('IR')
irw  = load('IRW')
stuck_sec = int(os.environ.get('STUCK_SEC', '14400'))

now = dt.datetime.now(dt.timezone.utc)

seen = {}
# needs-clarification + blocked: always include
for iss in nc + bl:
    n = iss['number']
    if n not in seen:
        seen[n] = iss

# operational: include only if older than stuck threshold
for iss in ip + ir + irw:
    n = iss['number']
    if n in seen:
        continue
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z', '+00:00'))
    age_s = (now - up).total_seconds()
    if age_s >= stuck_sec:
        seen[n] = iss

if not seen:
    import sys; sys.exit(0)

for iss in seen.values():
    up = dt.datetime.fromisoformat(iss['updatedAt'].replace('Z', '+00:00'))
    age_h = int((now - up).total_seconds() / 3600)
    labels = ','.join(l['name'] for l in iss.get('labels', []))
    title  = iss['title'].replace('\t', ' ')[:80]
    print(f"{age_h}\t{iss['number']}\t{labels}\t{title}")
PY
    )

    [ -z "$merged_json" ] && return 0

    while IFS=$'\t' read -r age_h number labels title; do
        [ -z "$number" ] && continue
        local comment
        comment=$(fetch_last_comment "$repo" "$number")
        printf '%s\t%s\t%s\t%s\t%s\n' "$age_h" "$number" "$labels" "$title" "$comment"
    done <<< "$merged_json"
}

# Build one project section of the digest, sorted by age descending (oldest first).
# Returns formatted Markdown lines on stdout; empty output means no stuck items.
build_project_section() {
    local slug="$1" repo="$2"
    local raw
    raw=$(collect_project_items "$repo") || true
    [ -z "$raw" ] && return 0

    # Sort by age_h descending (oldest first) — field 1
    local sorted
    sorted=$(printf '%s\n' "$raw" | sort -t$'\t' -k1 -rn)

    printf '### %s (`%s`)\n' "$slug" "$repo"
    while IFS=$'\t' read -r age_h number labels title comment; do
        [ -z "$number" ] && continue
        local entry="- #${number} (${age_h}h) [${labels}] ${title}"
        if [ -n "$comment" ]; then
            entry="${entry} — ${comment}"
        fi
        printf '%s\n' "$entry"
    done <<< "$sorted"
    printf '\n'
}

# --- Main ---

log "digest start (dry_run=$DRY_RUN)"

digest_body=""

while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    # shellcheck source=../lib/config.sh
    if ! loop_load_project "$slug" 2>/dev/null; then
        log "skip $slug (config error)"
        continue
    fi
    section=$(build_project_section "$slug" "$REPO") || true
    [ -n "$section" ] && digest_body="${digest_body}${section}"
done < <(loop_list_slugs)

if [ -z "$digest_body" ]; then
    log "no stuck items — digest suppressed"
    exit 0
fi

timestamp=$(date '+%Y-%m-%d %H:%M %Z')
message="$(printf '## Loop Digest — %s\n\nItems waiting on human input:\n\n%s' "$timestamp" "$digest_body")"

log "posting digest ($(printf '%s' "$message" | wc -l | tr -d ' ') lines)"

if $DRY_RUN; then
    printf '%s\n' "$message"
else
    loop_notify "$message"
fi

log "digest done"
