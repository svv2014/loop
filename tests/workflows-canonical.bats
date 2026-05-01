#!/usr/bin/env bats
# tests/workflows-canonical.bats — every label referenced by a shipped
# workflow YAML must be a member of LOOP_CANONICAL_LABELS (or one of the
# narrow set of orthogonal labels Loop allows in transition targets).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    # shellcheck source=../lib/labels.sh
    source "$REPO_ROOT/lib/labels.sh"
    # shellcheck source=../lib/workflow.sh
    source "$REPO_ROOT/lib/workflow.sh"
}

# Walk a workflow YAML and emit every label it references — every
# trigger_label and every transition target. One label per line.
_workflow_labels() {
    local yaml_path="$1"
    YAML="$yaml_path" python3 - <<'PY'
import os, sys, yaml

with open(os.environ['YAML']) as f:
    wf = yaml.safe_load(f) or {}

labels = []
for section in ('issue_stages', 'pr_stages'):
    for stage in wf.get(section, []) or []:
        lbl = stage.get('trigger_label')
        if lbl:
            labels.append(lbl)
        for field in ('on_done', 'on_blocked', 'on_clarification',
                      'on_failed_after_max', 'on_pass', 'on_fail'):
            v = stage.get(field)
            if v:
                labels.append(v)
        for v in (stage.get('decisions') or {}).values():
            if v:
                labels.append(v)

for l in labels:
    print(l)
PY
}

# `needs-clarification` is the one orthogonal label that may appear as a
# transition target — it's an out-of-band blocker (handler signal that the
# issue author is needed) and intentionally not part of the canonical
# pipeline state set in LOOP_CANONICAL_LABELS.
_label_is_allowed() {
    local label="$1"
    [ "$label" = "needs-clarification" ] && return 0
    loop_is_canonical_label "$label"
}

@test "default.yaml: every referenced label is canonical" {
    local yaml="$REPO_ROOT/config/workflows/default.yaml"
    [ -f "$yaml" ]
    while IFS= read -r label; do
        [ -z "$label" ] && continue
        run _label_is_allowed "$label"
        [ "$status" -eq 0 ] || {
            echo "default.yaml references non-canonical label: '$label'" >&2
            return 1
        }
    done < <(_workflow_labels "$yaml")
}

@test "minimal.yaml: every referenced label is canonical" {
    local yaml="$REPO_ROOT/config/workflows/minimal.yaml"
    [ -f "$yaml" ]
    while IFS= read -r label; do
        [ -z "$label" ] && continue
        run _label_is_allowed "$label"
        [ "$status" -eq 0 ] || {
            echo "minimal.yaml references non-canonical label: '$label'" >&2
            return 1
        }
    done < <(_workflow_labels "$yaml")
}

@test "docs-only.yaml: every referenced label is canonical" {
    local yaml="$REPO_ROOT/config/workflows/docs-only.yaml"
    [ -f "$yaml" ]
    while IFS= read -r label; do
        [ -z "$label" ] && continue
        run _label_is_allowed "$label"
        [ "$status" -eq 0 ] || {
            echo "docs-only.yaml references non-canonical label: '$label'" >&2
            return 1
        }
    done < <(_workflow_labels "$yaml")
}

@test "all shipped workflows pass loop_workflow_validate" {
    for wf in default minimal docs-only; do
        run loop_workflow_validate "$REPO_ROOT/config/workflows/${wf}.yaml"
        [ "$status" -eq 0 ] || {
            echo "loop_workflow_validate failed on ${wf}.yaml" >&2
            return 1
        }
    done
}

@test "no deprecated alias appears as a workflow label" {
    local deprecated
    deprecated=$(loop_deprecated_aliases | tr '\n' '|' | sed 's/|$//')
    for wf in default minimal docs-only; do
        local yaml="$REPO_ROOT/config/workflows/${wf}.yaml"
        while IFS= read -r label; do
            [ -z "$label" ] && continue
            if echo "$label" | grep -Eqx "$deprecated"; then
                echo "${wf}.yaml uses deprecated label: '$label'" >&2
                return 1
            fi
        done < <(_workflow_labels "$yaml")
    done
}
