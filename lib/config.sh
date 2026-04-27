#!/usr/bin/env bash
# lib/config.sh — sourced helper. Parses config/projects.yaml via python3+pyyaml.

set -euo pipefail

LOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$(cd "$LOOP_LIB_DIR/.." && pwd)"
LOOP_CONFIG="${LOOP_CONFIG:-$LOOP_ROOT/config/projects.yaml}"

# loop_load_project <slug>
# Exports: REPO ROOT DEFAULT_BRANCH COMMIT_PREFIX MERGE_STRATEGY AUTO_REBASE
#          DEV_VALIDATION_CMD QA_VALIDATION_CMD QA_BROWSER_URL NAME BACKEND
#          MAX_CONCURRENT_PRS
# BACKEND defaults to 'github' when not specified in projects.yaml.
# Returns non-zero if the slug is not found.
loop_load_project() {
    local slug="$1"
    local config="$LOOP_CONFIG"

    [ -f "$config" ] || { echo "loop_load_project: config not found: $config" >&2; return 2; }

    local out
    out=$(python3 - "$config" "$slug" <<'PY'
import sys, yaml
cfg_path, slug = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    data = yaml.safe_load(f) or {}
for p in data.get("projects", []) or []:
    if p.get("slug") == slug:
        dev = p.get("dev") or {}
        qa  = p.get("qa") or {}
        mg  = p.get("merge") or {}
        def sh(v): return "" if v is None else str(v).replace("'", "'\\''")
        print(f"NAME='{sh(p.get('name',''))}'")
        print(f"REPO='{sh(p.get('repo',''))}'")
        print(f"ROOT='{sh(p.get('root',''))}'")
        print(f"DEFAULT_BRANCH='{sh(p.get('default_branch','main'))}'")
        print(f"COMMIT_PREFIX='{sh(dev.get('commit_prefix', slug.upper()))}'")
        print(f"DEV_VALIDATION_CMD='{sh(dev.get('validation_cmd',''))}'")
        print(f"QA_VALIDATION_CMD='{sh(qa.get('validation_cmd',''))}'")
        print(f"QA_BROWSER_URL='{sh(qa.get('browser_url',''))}'")
        print(f"QA_TIMEOUT_SECONDS='{sh(qa.get('timeout_seconds',''))}'")
        print(f"HANDLER_TIMEOUT_SECONDS='{sh(dev.get('handler_timeout_seconds',''))}'")
        print(f"MERGE_STRATEGY='{sh(mg.get('strategy','squash'))}'")
        print(f"AUTO_REBASE='{'true' if mg.get('auto_rebase', False) else 'false'}'")
        print(f"BACKEND='{sh(p.get('backend','github'))}'")
        print(f"MAX_CONCURRENT_PRS='{sh(dev.get('max_concurrent_prs', 1))}'")
        # model: per-project override → global default_model → hardcoded fallback
        global_model = data.get("default_model") or "claude-sonnet-4-6"
        project_model = p.get("model") or global_model
        print(f"LOOP_AGENT_MODEL='{sh(project_model)}'")
        # allowed_authors: per-project override, falls back to global setting
        global_authors = data.get("allowed_authors") or []
        project_authors = p.get("allowed_authors") or global_authors
        authors_str = ",".join(str(a) for a in project_authors)
        print(f"ALLOWED_AUTHORS='{sh(authors_str)}'")
        sys.exit(0)
sys.exit(1)
PY
)
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "loop_load_project: slug '$slug' not found in $config" >&2
        return 1
    fi
    eval "$out"
    export NAME REPO ROOT DEFAULT_BRANCH COMMIT_PREFIX DEV_VALIDATION_CMD QA_VALIDATION_CMD QA_BROWSER_URL QA_TIMEOUT_SECONDS HANDLER_TIMEOUT_SECONDS MERGE_STRATEGY AUTO_REBASE BACKEND MAX_CONCURRENT_PRS LOOP_AGENT_MODEL ALLOWED_AUTHORS
}

# loop_list_slugs — print each project slug on its own line
loop_list_slugs() {
    local config="$LOOP_CONFIG"
    [ -f "$config" ] || { echo "loop_list_slugs: config not found: $config" >&2; return 2; }
    python3 - "$config" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
for p in data.get("projects", []) or []:
    s = p.get("slug")
    if s:
        print(s)
PY
}
