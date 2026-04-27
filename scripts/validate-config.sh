#!/usr/bin/env bash
# scripts/validate-config.sh — validate config/projects.yaml (v1 schema).
#
# Usage:
#   ./scripts/validate-config.sh [path-to-config]
#
# Checks:
#   1. File exists and parses as valid YAML
#   2. Slug uniqueness across all projects
#   3. Repo uniqueness across all projects
#   4. Workflow file existence (config/workflows/<name>.yaml)
#   5. Label override key validity (non-empty strings)
#   6. ${HOME} substitution in root paths
#
# Exits 0 on success, 1 on validation failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_PATH="${1:-$LOOP_ROOT/config/projects.yaml}"

if [ ! -f "$CONFIG_PATH" ]; then
    echo "[validate] ERROR: config not found: $CONFIG_PATH" >&2
    exit 1
fi

python3 - "$CONFIG_PATH" "$LOOP_ROOT" "$HOME" <<'PY'
import sys, yaml, os

cfg_path, loop_root, home = sys.argv[1], sys.argv[2], sys.argv[3]
workflows_dir = os.path.join(loop_root, "config", "workflows")

errors = []
warnings = []

# Parse YAML
try:
    with open(cfg_path) as f:
        data = yaml.safe_load(f) or {}
except yaml.YAMLError as e:
    print(f"[validate] ERROR: YAML parse error in {cfg_path}: {e}", file=sys.stderr)
    sys.exit(1)

# v0 legacy warning
version = data.get("version")
if version is None:
    warnings.append("no 'version' field — add 'version: 1' to adopt the v1 schema")
elif version != 1:
    warnings.append(f"unexpected version '{version}' — only version 1 is supported")

projects = data.get("projects") or []

seen_slugs = {}
seen_repos = {}

for idx, p in enumerate(projects):
    loc = f"projects[{idx}]"
    slug = p.get("slug") or ""
    repo = p.get("repo") or ""

    if not slug:
        errors.append(f"{loc}: missing required field 'slug'")
    elif slug in seen_slugs:
        errors.append(f"{loc}: duplicate slug '{slug}' (first seen at {seen_slugs[slug]})")
    else:
        seen_slugs[slug] = loc

    if not repo:
        errors.append(f"{loc} (slug={slug!r}): missing required field 'repo'")
    elif repo in seen_repos:
        errors.append(f"{loc} (slug={slug!r}): duplicate repo '{repo}' (first seen at {seen_repos[repo]})")
    else:
        seen_repos[repo] = loc

    # Workflow file existence
    workflow = p.get("workflow") or "default"
    wf_file = os.path.join(workflows_dir, f"{workflow}.yaml")
    if not os.path.isfile(wf_file):
        errors.append(
            f"{loc} (slug={slug!r}): workflow '{workflow}' not found at "
            f"config/workflows/{workflow}.yaml"
        )

    # Label override key validity
    label_map = p.get("labels") or {}
    if not isinstance(label_map, dict):
        errors.append(f"{loc} (slug={slug!r}): 'labels' must be a mapping")
    else:
        for k, v in label_map.items():
            if not k or not isinstance(k, str) or not k.strip():
                errors.append(f"{loc} (slug={slug!r}): invalid label key: {k!r}")
            if not v or not isinstance(v, str) or not v.strip():
                errors.append(f"{loc} (slug={slug!r}): invalid label override value for '{k}': {v!r}")

    # ${HOME} substitution in root path
    root_raw = p.get("root") or ""
    if "${HOME}" in root_raw or "$HOME" in root_raw:
        substituted = root_raw.replace("${HOME}", home).replace("$HOME", home)
        warnings.append(
            f"{loc} (slug={slug!r}): 'root' contains $HOME placeholder — "
            f"resolved to: {substituted}"
        )

# Print results
for w in warnings:
    print(f"[validate] WARN:  {w}", file=sys.stderr)

if errors:
    for e in errors:
        print(f"[validate] ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print(f"[validate] OK: {cfg_path} ({len(projects)} project(s))")
PY
