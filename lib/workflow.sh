#!/usr/bin/env bash
# lib/workflow.sh — workflow loader and lookup helpers.
#
# Workflows are declared in config/workflows/<name>.yaml. Each project in
# config/projects.yaml references one via its `workflow:` field, and may
# override individual label names via a `labels:` map. This file provides
# label/handler lookups that the scanner and handlers use instead of
# hardcoded names.
#
# Sourced by lib/env.sh. Compatible with bash 3.x (no associative arrays).
#
# Public API:
#   loop_workflow_for_project <slug>            # echo workflow name for a project
#   loop_label_for <slug> <canonical>           # echo label name with overrides applied
#   loop_polled_labels <slug> <issue|pr>        # list labels the scanner should poll
#   loop_handler_for_label <slug> <label>       # echo handler base name
#   loop_workflow_validate <path>               # exit 0 if file is schema-v1 valid

# Sourced libs should not enable -u (would crash callers); leave shell defaults.

_LOOP_WORKFLOW_DIR="${LOOP_WORKFLOW_DIR:-${LOOP_ROOT:-.}/config/workflows}"

# loop_workflow_for_project <slug>
# Reads config/projects.yaml and returns the workflow name. Defaults to "default".
loop_workflow_for_project() {
    local slug="$1"
    local config="${LOOP_CONFIG:-${LOOP_ROOT:-.}/config/projects.yaml}"
    if [ ! -f "$config" ]; then
        echo "default"
        return 0
    fi
    SLUG="$slug" CFG="$config" python3 - <<'PY'
import os, sys, yaml
slug = os.environ['SLUG']
with open(os.environ['CFG']) as f:
    data = yaml.safe_load(f) or {}
for p in data.get('projects', []):
    if p.get('slug') == slug:
        print(p.get('workflow', 'default'))
        sys.exit(0)
print('default')
PY
}

# loop_label_for <slug> <canonical>
# Returns the project-specific label name for a canonical workflow label.
loop_label_for() {
    local slug="$1" canonical="$2"
    local config="${LOOP_CONFIG:-${LOOP_ROOT:-.}/config/projects.yaml}"
    if [ ! -f "$config" ]; then
        echo "$canonical"
        return 0
    fi
    SLUG="$slug" CANON="$canonical" CFG="$config" python3 - <<'PY'
import os, sys, yaml
slug = os.environ['SLUG']
canon = os.environ['CANON']
with open(os.environ['CFG']) as f:
    data = yaml.safe_load(f) or {}
for p in data.get('projects', []):
    if p.get('slug') == slug:
        overrides = p.get('labels') or {}
        print(overrides.get(canon, canon))
        sys.exit(0)
print(canon)
PY
}

# loop_polled_labels <slug> <target>
# target = "issue" or "pr". Returns one label per line.
loop_polled_labels() {
    local slug="$1" target="$2"
    local wf
    wf=$(loop_workflow_for_project "$slug")
    local wf_file="$_LOOP_WORKFLOW_DIR/${wf}.yaml"
    if [ ! -f "$wf_file" ]; then
        echo "[workflow] WARN: workflow file not found: $wf_file" >&2
        return 0
    fi
    SLUG="$slug" WF="$wf_file" TARGET="$target" \
    CFG="${LOOP_CONFIG:-${LOOP_ROOT:-.}/config/projects.yaml}" python3 - <<'PY'
import os, sys, yaml
slug = os.environ['SLUG']
target = os.environ['TARGET']
with open(os.environ['WF']) as f:
    wf = yaml.safe_load(f) or {}
overrides = {}
cfg_path = os.environ.get('CFG', '')
if cfg_path and os.path.isfile(cfg_path):
    with open(cfg_path) as f:
        data = yaml.safe_load(f) or {}
    for p in data.get('projects', []):
        if p.get('slug') == slug:
            overrides = p.get('labels') or {}
            break
key = 'issue_stages' if target == 'issue' else 'pr_stages'
for stage in wf.get(key, []) or []:
    canonical = stage.get('trigger_label')
    if canonical:
        print(overrides.get(canonical, canonical))
PY
}

# loop_stage_trigger <slug> <stage_id> [target]
# Returns the actual label that triggers a workflow stage for a project.
# Walks the project's active workflow, finds stage by id, returns its
# trigger_label with project label overrides applied.
# stage_id: po | dev | plan | review | rework | qa | merge (workflow-defined)
# target (optional): 'issue' or 'pr' to disambiguate stage_id collisions.
#
# This is what scanner.sh should use instead of asking for hardcoded
# canonical names — those exist only in `default` workflow. For projects
# on `current` (or any custom) workflow, the trigger labels are different
# and only the workflow file knows them.
loop_stage_trigger() {
    local slug="$1" stage_id="$2" target="${3:-}"
    local wf
    wf=$(loop_workflow_for_project "$slug")
    local wf_file="$_LOOP_WORKFLOW_DIR/${wf}.yaml"
    [ -f "$wf_file" ] || { echo "[workflow] WARN: $wf_file not found" >&2; return 1; }
    SLUG="$slug" WF="$wf_file" SID="$stage_id" TGT="$target" \
    CFG="${LOOP_CONFIG:-${LOOP_ROOT:-.}/config/projects.yaml}" python3 - <<'PY'
import os, sys, yaml
sid = os.environ['SID']
target = os.environ.get('TGT', '')
with open(os.environ['WF']) as f:
    wf = yaml.safe_load(f) or {}
overrides = {}
cfg = os.environ.get('CFG', '')
if cfg and os.path.isfile(cfg):
    with open(cfg) as f:
        data = yaml.safe_load(f) or {}
    for p in data.get('projects', []):
        if p.get('slug') == os.environ['SLUG']:
            overrides = p.get('labels') or {}
            break
sections = ['issue_stages', 'pr_stages']
if target == 'issue':
    sections = ['issue_stages']
elif target == 'pr':
    sections = ['pr_stages']
for sec in sections:
    for stage in wf.get(sec, []) or []:
        if stage.get('id') == sid:
            canonical = stage.get('trigger_label')
            if canonical:
                print(overrides.get(canonical, canonical))
                sys.exit(0)
sys.exit(1)
PY
}

# loop_handler_for_label <slug> <label>
# Given an actually-applied label (post-override), returns the handler script base name.
loop_handler_for_label() {
    local slug="$1" label="$2"
    local wf
    wf=$(loop_workflow_for_project "$slug")
    local wf_file="$_LOOP_WORKFLOW_DIR/${wf}.yaml"
    [ -f "$wf_file" ] || return 1
    SLUG="$slug" WF="$wf_file" LBL="$label" \
    CFG="${LOOP_CONFIG:-${LOOP_ROOT:-.}/config/projects.yaml}" python3 - <<'PY'
import os, sys, yaml
slug = os.environ['SLUG']
label = os.environ['LBL']
with open(os.environ['WF']) as f:
    wf = yaml.safe_load(f) or {}
overrides = {}
cfg_path = os.environ.get('CFG', '')
if cfg_path and os.path.isfile(cfg_path):
    with open(cfg_path) as f:
        data = yaml.safe_load(f) or {}
    for p in data.get('projects', []):
        if p.get('slug') == slug:
            overrides = p.get('labels') or {}
            break
reverse = {v: k for k, v in overrides.items()}
canonical = reverse.get(label, label)
for section in ('issue_stages', 'pr_stages'):
    for stage in wf.get(section, []) or []:
        if stage.get('trigger_label') == canonical:
            print(stage.get('handler', ''))
            sys.exit(0)
sys.exit(1)
PY
}

# loop_workflow_validate <path>
# Exit 0 if schema-v1 valid; non-zero with stderr message otherwise.
# Warns (does not fail) for handler scripts not found on disk.
loop_workflow_validate() {
    local path="$1"
    [ -f "$path" ] || { echo "[workflow] not a file: $path" >&2; return 2; }
    PTH="$path" SCRIPTS_DIR="${LOOP_ROOT:-.}/scripts" python3 - <<'PY'
import os, sys, yaml

path = os.environ['PTH']
scripts_dir = os.environ.get('SCRIPTS_DIR', 'scripts')

# Labels valid as transition targets without needing to be trigger_labels.
# Includes terminal states and outcome labels that don't launch a handler.
TERMINAL_LABELS = {'done', 'blocked', 'needs-clarification', 'qa-fail'}

try:
    with open(path) as f:
        wf = yaml.safe_load(f) or {}
except Exception as e:
    print(f"[workflow] {path}: parse error: {e}", file=sys.stderr); sys.exit(2)

errors = []
warnings = []

if wf.get('version') != 1:
    errors.append("missing or non-1 'version' field")

name = wf.get('name')
if not name:
    errors.append("missing 'name'")
else:
    expected = os.path.splitext(os.path.basename(path))[0]
    if name != expected:
        errors.append(f"'name' field '{name}' does not match filename '{expected}'")

stages_total = 0
seen_labels = set()
all_handlers = []
all_transitions = []  # (field_name, value)

# Duplicate trigger_label check is per-section: issues and PRs are distinct
# objects, so a label like `needs-dev` may legitimately trigger an issue
# stage and a PR-rework stage in the same workflow.
for section in ('issue_stages', 'pr_stages'):
    section_labels = set()
    for s in wf.get(section, []) or []:
        stages_total += 1
        if 'id' not in s:
            errors.append(f"{section} stage missing 'id'")
        if 'trigger_label' not in s:
            errors.append(f"{section}/{s.get('id','?')} missing 'trigger_label'")
        if 'handler' not in s:
            errors.append(f"{section}/{s.get('id','?')} missing 'handler'")

        lbl = s.get('trigger_label')
        if lbl and lbl in section_labels:
            errors.append(f"duplicate trigger_label '{lbl}' within {section}")
        elif lbl:
            section_labels.add(lbl)
            seen_labels.add(lbl)

        handler = s.get('handler')
        if handler:
            all_handlers.append(handler)

        # Collect transition targets
        for field in ('on_done', 'on_blocked', 'on_clarification',
                      'on_failed_after_max', 'on_pass', 'on_fail'):
            val = s.get(field)
            if val:
                all_transitions.append((field, val))
        decisions = s.get('decisions') or {}
        for decision_val in decisions.values():
            all_transitions.append(('decisions', decision_val))

if stages_total == 0:
    errors.append("workflow has zero stages")

# Validate transition targets: must be a trigger_label in the file or a terminal label.
known_labels = seen_labels | TERMINAL_LABELS
for field, target in all_transitions:
    if target not in known_labels:
        errors.append(f"transition target '{target}' (in '{field}') is not a known label or terminal label")

# Warn (do not fail) for missing handler scripts.
for handler in all_handlers:
    script = os.path.join(scripts_dir, handler + '.sh')
    if not os.path.isfile(script):
        warnings.append(f"handler script not found (non-fatal): {script}")

for w in warnings:
    print(f"[workflow] WARN {path}: {w}", file=sys.stderr)

if errors:
    for e in errors:
        print(f"[workflow] {path}: {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}
