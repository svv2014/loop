#!/usr/bin/env bash
# lib/author_gate.sh — author-gate digest helpers for the reconciler.
#
# When ALLOWED_AUTHORS is configured for a project, the scanner silently
# skips any issue/PR opened by an author outside that allow-list. Operators
# have no easy way to see what is parked. This helper produces a structured
# one-line-per-ticket summary and a per-slug counter that `loop status`
# surfaces as `author_gated_pending=N`.
#
# Tickets carrying the `operator-approved` label are treated as bypassed
# (handled by the sibling override-label issue) and are excluded from the
# digest.

# State directory holding per-slug counter files. Defaults under LOOP_LOG_DIR
# but can be overridden in tests.
: "${LOOP_AUTHOR_GATED_DIR:=${LOOP_LOG_DIR:-/tmp}/author-gated}"

# author_gate_state_dir
# Echo the directory used to persist per-slug counters.
author_gate_state_dir() {
    printf '%s\n' "$LOOP_AUTHOR_GATED_DIR"
}

# author_gate_count_file <slug>
author_gate_count_file() {
    printf '%s/%s.count\n' "$LOOP_AUTHOR_GATED_DIR" "$1"
}

# author_gate_pending_total
# Sum the pending counts across every slug. Empty / missing dir → 0.
author_gate_pending_total() {
    local total=0 f n
    [ -d "$LOOP_AUTHOR_GATED_DIR" ] || { echo 0; return 0; }
    for f in "$LOOP_AUTHOR_GATED_DIR"/*.count; do
        [ -f "$f" ] || continue
        n=$(tr -d '[:space:]' < "$f" 2>/dev/null || echo 0)
        [ -n "$n" ] || n=0
        total=$(( total + n ))
    done
    echo "$total"
}

# reconcile_author_gated <slug> <repo>
# Emits one structured log line per gated ticket and writes the count to a
# state file consumed by `loop status`. Dedup is per (slug, number) so an
# entry that appears in both the issues and PRs query (shared numbering) is
# only reported once. Requires globals: ALLOWED_AUTHORS, log().
reconcile_author_gated() {
    local slug="$1" repo="$2"

    mkdir -p "$LOOP_AUTHOR_GATED_DIR"
    local count_file
    count_file=$(author_gate_count_file "$slug")

    if [ -z "${ALLOWED_AUTHORS:-}" ]; then
        # No gate configured — clear any stale counter and exit.
        echo 0 > "$count_file"
        return 0
    fi

    log "[$repo] scanning author-gated tickets (allow-list=${ALLOWED_AUTHORS})"

    local issues_json prs_json
    issues_json=$(gh issue list --repo "$repo" --state open --limit 200 \
        --json number,title,labels,author,createdAt 2>/dev/null || echo "[]")
    prs_json=$(gh pr list --repo "$repo" --state open --limit 200 \
        --json number,title,labels,author,createdAt 2>/dev/null || echo "[]")

    local digest
    digest=$(SLUG="$slug" ALLOWED="$ALLOWED_AUTHORS" \
             ISSUES="$issues_json" PRS="$prs_json" python3 - <<'PY'
import json, os, datetime as dt

slug = os.environ['SLUG']
allowed = {a.strip() for a in os.environ['ALLOWED'].split(',') if a.strip()}
issues = json.loads(os.environ['ISSUES'] or '[]')
prs = json.loads(os.environ['PRS'] or '[]')
now = dt.datetime.now(dt.timezone.utc)

seen = set()
lines = []
for items in (issues, prs):
    for it in items:
        num = it.get('number')
        if num is None:
            continue
        key = (slug, num)
        if key in seen:
            continue
        author_obj = it.get('author') or {}
        author = author_obj.get('login') or author_obj.get('name') or ''
        if not author or author in allowed:
            continue
        labels = {
            (l.get('name') if isinstance(l, dict) else l)
            for l in (it.get('labels') or [])
        }
        if 'operator-approved' in labels:
            continue
        try:
            ts = dt.datetime.fromisoformat(
                (it.get('createdAt') or '').replace('Z', '+00:00'))
            age_h = max(0, int((now - ts).total_seconds() // 3600))
        except Exception:
            age_h = 0
        title = (it.get('title') or '').replace('\n', ' ').strip()[:80]
        seen.add(key)
        lines.append(
            f"author_gated: slug={slug} num={num} author={author} "
            f"age={age_h}h title={title}")

for line in lines:
    print(line)
PY
)

    local count=0
    if [ -n "$digest" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            log "$line"
            count=$(( count + 1 ))
        done <<< "$digest"
    fi

    echo "$count" > "$count_file"
    log "[$repo] author_gated_pending=$count (slug=$slug)"
}

# loop_project_has_author_gate <slug>
# Returns 0 (success) iff ALLOWED_AUTHORS is set and non-empty for the current
# project. Must be called after loop_load_project so ALLOWED_AUTHORS is exported.
loop_project_has_author_gate() {
    [ -n "${ALLOWED_AUTHORS:-}" ]
}

# security_misconfig_count_file
# Path to the file that the scanner writes its per-tick misconfig count to.
security_misconfig_count_file() {
    printf '%s/security-misconfig.count\n' "${LOOP_LOG_DIR:-/tmp}"
}

# security_misconfig_total
# Read the scanner's last-written misconfig count. Returns 0 if unset.
security_misconfig_total() {
    local f; f=$(security_misconfig_count_file)
    [ -f "$f" ] || { echo 0; return 0; }
    local n; n=$(tr -d '[:space:]' < "$f" 2>/dev/null || echo 0)
    printf '%s\n' "${n:-0}"
}
