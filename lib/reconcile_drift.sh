#!/usr/bin/env bash
# lib/reconcile_drift.sh — issue↔PR label drift detection (subsumes #127).
#
# Detects the cases enumerated in #127: an open PR whose pipeline label has
# advanced past the linked issue's pipeline label (or vice versa). Repairs
# unambiguously where the PR carries a single mapped pipeline label;
# otherwise flags the issue with `needs-clarification` for human triage.
#
# Mapping (PR label → expected issue label), expressed in canonical form
# per lib/labels.sh:
#
#   PR has  in-dev        →  issue must be  in-dev
#   PR has  needs-dev     →  issue must be  in-dev
#   PR has  needs-review  →  issue must be  needs-review
#   PR has  in-review     →  issue must be  needs-review
#   PR has  needs-qa      →  issue must be  needs-review
#
# Inputs (function-scoped):
#   $REPO must be set by the caller (loop_load_project).
#   Backend functions backend_list_open_prs_raw / backend_list_open_issues_raw
#   / backend_*_label / backend_comment_issue must be loaded.
#
# Outputs (caller-visible globals, incremented in place):
#   DRIFT_REPAIRED      — issues whose label was corrected
#   BLOCKED_REPORTED    — issues flagged needs-clarification due to
#                         ambiguous PR state (multiple mapped pipeline
#                         labels active simultaneously)
#
# Honours $DRY_RUN: in dry-run mode, counters still advance but no
# mutations are performed.

if [ "${_LOOP_RECONCILE_DRIFT_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_LOOP_RECONCILE_DRIFT_LOADED=1

# Drift mapping table: "<pr_canonical> <expected_issue_canonical>" per line.
# Kept here (not in lib/labels.sh) because it is policy, not vocabulary.
_LOOP_DRIFT_MAP=$(cat <<'EOF'
in-dev in-dev
needs-dev in-dev
needs-review needs-review
in-review needs-review
needs-qa needs-review
EOF
)

# Read JSON-encoded PR and issue lists, emit one drift record per offending
# linked issue. Output (TAB-separated):
#   <issue_num>\t<verdict>\t<expected>\t<current>\t<pr_num>
# verdict ∈ {repair, ambiguous}
_loop_drift_classify() {
    local prs_json="$1" issues_json="$2"
    PJSON="$prs_json" IJSON="$issues_json" \
        DRIFT_MAP="$_LOOP_DRIFT_MAP" \
        python3 - <<'PY'
import json, os, re

prs = json.loads(os.environ['PJSON'])
issues = json.loads(os.environ['IJSON'])

mapping = {}
for line in os.environ['DRIFT_MAP'].splitlines():
    line = line.strip()
    if not line: continue
    k, v = line.split()
    mapping[k] = v

# Alias normalisation mirrors LOOP_DEPRECATED_ALIAS_MAP in lib/labels.sh.
ALIAS = {
    "review-pending":    "needs-review",
    "needs-rework":      "needs-dev",
    "changes-requested": "needs-dev",
    "in-rework":         "in-dev",
}
def canon(name): return ALIAS.get(name, name)

issue_by_num = {i['number']: i for i in issues}
closes_re = re.compile(
    r'(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\s+#(\d+)', re.I)

map_keys = set(mapping.keys())
map_vals = set(mapping.values())

for pr in prs:
    pr_labels = {canon(l['name']) if isinstance(l, dict) else canon(l)
                 for l in pr.get('labels', [])}
    pr_keys = pr_labels & map_keys
    if not pr_keys:
        continue
    expected_set = {mapping[k] for k in pr_keys}

    body = pr.get('body') or ''
    for n in {int(m) for m in closes_re.findall(body)}:
        iss = issue_by_num.get(n)
        if not iss: continue
        iss_labels = {canon(l['name']) if isinstance(l, dict) else canon(l)
                      for l in iss.get('labels', [])}
        if iss_labels & {"needs-clarification", "blocked", "done"}:
            continue
        cur_pipe = sorted(iss_labels & map_vals)
        cur_str = ','.join(cur_pipe) if cur_pipe else '<none>'

        if len(expected_set) > 1:
            print(f"{n}\tambiguous\t{','.join(sorted(expected_set))}\t{cur_str}\t{pr['number']}")
            continue

        expected = next(iter(expected_set))
        if expected in iss_labels:
            continue
        print(f"{n}\trepair\t{expected}\t{cur_str}\t{pr['number']}")
PY
}

# Public: run drift detection for $REPO. Mutates DRIFT_REPAIRED and
# BLOCKED_REPORTED globals; never returns non-zero on individual failures.
reconcile_drift_run() {
    local repo="${REPO:?REPO not set}"
    local prs_json issues_json
    prs_json=$(backend_list_open_prs_raw "$repo" 2>/dev/null || echo "[]")
    issues_json=$(backend_list_open_issues_raw "$repo" "" 2>/dev/null || echo "[]")

    local records
    records=$(_loop_drift_classify "$prs_json" "$issues_json") || records=""
    [ -z "$records" ] && return 0

    local issue_num verdict expected current pr_num current_label
    while IFS=$'\t' read -r issue_num verdict expected current pr_num; do
        [ -z "$issue_num" ] && continue
        case "$verdict" in
            repair)
                if declare -F log >/dev/null; then
                    log "[$repo] DRIFT issue #$issue_num: PR#$pr_num implies '$expected', issue has '$current' — repairing"
                fi
                DRIFT_REPAIRED=$((DRIFT_REPAIRED + 1))
                ${DRY_RUN:-false} && continue
                if [ "$current" != "<none>" ]; then
                    IFS=',' read -r -a _cur_arr <<< "$current"
                    for current_label in "${_cur_arr[@]}"; do
                        [ "$current_label" = "$expected" ] && continue
                        backend_remove_label "$repo" "$issue_num" "$current_label" 2>/dev/null || true
                    done
                fi
                backend_add_label "$repo" "$issue_num" "$expected" 2>/dev/null || true
                ;;
            ambiguous)
                if declare -F log >/dev/null; then
                    log "[$repo] DRIFT-AMBIGUOUS issue #$issue_num: PR#$pr_num maps to {$expected} — needs-clarification"
                fi
                BLOCKED_REPORTED=$((BLOCKED_REPORTED + 1))
                ${DRY_RUN:-false} && continue
                backend_add_label "$repo" "$issue_num" needs-clarification 2>/dev/null || true
                backend_comment_issue "$repo" "$issue_num" \
                    "Reconciler: linked PR #$pr_num carries conflicting pipeline labels mapping to multiple expected issue states ({$expected}). Manual triage required." \
                    2>/dev/null || true
                ;;
        esac
    done <<< "$records"
}
