#!/usr/bin/env bash
# lint-workflow.sh — state-machine audit of workflow YAML files.
#
# For each workflow file (default: every YAML in config/workflows/):
#   1. Enumerate every label declared by the workflow (trigger_label values
#      and every label produced by a handler output — on_done, on_blocked,
#      on_clarification, on_failed_after_max, on_pass, on_fail, decisions.*).
#   2. Build the state-machine graph: trigger labels are states, handler
#      outputs are transitions.
#   3. Flag DEAD-ENDS: labels that a handler can SET but no stage triggers on.
#   4. Flag ORPHAN TRIGGERS: trigger_labels that no handler ever produces and
#      that are not the workflow's entry point (the first issue_stages trigger).
#
# Terminal labels (`done`, `blocked`, `needs-clarification`) are valid sinks
# and never flagged.
#
# Usage:
#   ./scripts/lint-workflow.sh                          # lint every file
#   ./scripts/lint-workflow.sh path/to/workflow.yaml    # lint one file
#
# Exit codes:
#   0 — no dead-ends, no orphan triggers
#   1 — at least one issue found

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -eq 0 ]; then
    set -- "$LOOP_ROOT"/config/workflows/*.yaml
fi

failed=0
for path in "$@"; do
    [ -e "$path" ] || continue

    out=$(WF_PATH="$path" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    print(f"[error] pyyaml not installed; cannot lint {os.environ['WF_PATH']}", file=sys.stderr)
    sys.exit(2)

path = os.environ['WF_PATH']
with open(path) as f:
    wf = yaml.safe_load(f) or {}

TERMINALS = {
    'done', 'blocked', 'needs-clarification',
    'loop:result:done', 'loop:result:blocked',
}
PRODUCING_KEYS = (
    'on_done', 'on_blocked', 'on_clarification',
    'on_failed_after_max', 'on_pass', 'on_fail',
)

issue_stages = wf.get('issue_stages') or []
pr_stages = wf.get('pr_stages') or []
stages = list(issue_stages) + list(pr_stages)

triggers = set()
produced = set()
# {label: [(stage_id, key)]} — for diagnostics
produced_by = {}

for s in stages:
    if not isinstance(s, dict):
        continue
    t = s.get('trigger_label')
    if t:
        triggers.add(t)
    for key in PRODUCING_KEYS:
        v = s.get(key)
        if isinstance(v, str) and v:
            produced.add(v)
            produced_by.setdefault(v, []).append((s.get('id', '?'), key))
    decisions = s.get('decisions') or {}
    if isinstance(decisions, dict):
        for dk, dv in decisions.items():
            if isinstance(dv, str) and dv:
                produced.add(dv)
                produced_by.setdefault(dv, []).append(
                    (s.get('id', '?'), f'decisions.{dk}'))

# Entry point: trigger of the first issue stage (if any), else first PR stage.
entry = None
if issue_stages and isinstance(issue_stages[0], dict):
    entry = issue_stages[0].get('trigger_label')
elif pr_stages and isinstance(pr_stages[0], dict):
    entry = pr_stages[0].get('trigger_label')

dead_ends = sorted(
    label for label in produced
    if label not in triggers and label not in TERMINALS
)
orphan_triggers = sorted(
    t for t in triggers
    if t not in produced and t != entry
)

problems = []
for label in dead_ends:
    setters = ', '.join(f'{sid}.{key}' for sid, key in produced_by[label])
    problems.append(f"dead-end label '{label}' set by [{setters}] but no stage triggers on it")
for t in orphan_triggers:
    problems.append(f"orphan trigger '{t}' — no handler in this workflow produces it (and it's not the workflow entry point)")

name = wf.get('name', os.path.basename(path))
if problems:
    print(f"[fail] {path} ({name}):")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)
else:
    n_states = len(triggers | produced | TERMINALS)
    print(f"[ok]   {path} ({name}) — {len(triggers)} triggers, {len(produced)} transitions, {n_states} states; no dead-ends, no orphans")
    sys.exit(0)
PY
    )
    rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "lint-workflow: $failed workflow file(s) failed" >&2
    exit 1
fi
exit 0
