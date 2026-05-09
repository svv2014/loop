#!/usr/bin/env bash
# lib/config.sh — sourced helper. Parses config/projects.yaml via python3+pyyaml.

set -euo pipefail

LOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$(cd "$LOOP_LIB_DIR/.." && pwd)"
LOOP_CONFIG="${LOOP_CONFIG:-$LOOP_ROOT/config/projects.yaml}"

# loop_load_project <slug>
# Exports: REPO ROOT DEFAULT_BRANCH COMMIT_PREFIX MERGE_STRATEGY AUTO_REBASE
#          DEV_VALIDATION_CMD QA_VALIDATION_CMD QA_BROWSER_URL NAME BACKEND
#          MAX_CONCURRENT_PRS WORKFLOW LOOP_LABEL_OVERRIDES
# BACKEND defaults to 'github' when not specified in projects.yaml.
# WORKFLOW defaults to 'default' when not specified.
# LOOP_LABEL_OVERRIDES is a pipe-separated list of canonical=override pairs.
# Returns non-zero if the slug is not found.
loop_load_project() {
    local slug="$1"
    local config="$LOOP_CONFIG"

    [ -f "$config" ] || { echo "loop_load_project: config not found: $config" >&2; return 2; }

    local out
    out=$(python3 - "$config" "$slug" <<'PY'
import sys, yaml, os
cfg_path, slug = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    data = yaml.safe_load(f) or {}

# v0 legacy fallback: warn when version field is absent
version = data.get("version")
if version is None:
    print("WARNING: projects.yaml has no 'version' field — assuming v0 (legacy). Add 'version: 1' to suppress this warning.", file=sys.stderr)

for p in data.get("projects", []) or []:
    if p.get("slug") == slug:
        dev = p.get("dev") or {}
        qa  = p.get("qa") or {}
        mg  = p.get("merge") or {}
        def sh(v): return "" if v is None else str(v).replace("'", "'\\''")

        # v1: workflow ref (defaults to "default")
        workflow = p.get("workflow") or "default"

        # v1: sparse label overrides — serialized as "canonical=override|..." pairs
        label_map = p.get("labels") or {}
        home = os.environ.get("HOME", "")
        label_overrides = "|".join(
            f"{k}={v}" for k, v in label_map.items()
        )

        # root: substitute ${HOME} and $HOME placeholders
        root_raw = p.get("root") or ""
        root_val = root_raw.replace("${HOME}", home).replace("$HOME", home)

        print(f"NAME='{sh(p.get('name',''))}'")
        print(f"REPO='{sh(p.get('repo',''))}'")
        print(f"ROOT='{sh(root_val)}'")
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
        # WORKTREE_EXTRA_PATHS: paths from the primary checkout to symlink into
        # each fresh worker worktree. Useful for projects with gitignored runtime
        # files (ML training data, downloaded models, large fixtures) that the
        # worker needs to read but that aren't tracked by git. Newline-delimited.
        # Configure per-project via `dev.worktree_extra_paths` in projects.yaml.
        wtep = dev.get("worktree_extra_paths") or []
        wtep_lines = [str(p).strip() for p in wtep if str(p).strip()]
        print(f"WORKTREE_EXTRA_PATHS='{sh(chr(10).join(wtep_lines))}'")
        # MAX_CONCURRENT_HANDLERS: caps emits-per-tick for all non-dev pipeline
        # stages (po, senior-dev, review, qa, merge, dev-rework). Dev has its
        # own slot system (MAX_CONCURRENT_PRS) — that stays separate.
        # Configure per-project via `pipeline.max_concurrent_handlers`,
        # globally via top-level `max_concurrent_handlers`. Default: 1.
        global_max_handlers = data.get("max_concurrent_handlers", 1)
        pipeline = p.get("pipeline") or {}
        print(f"MAX_CONCURRENT_HANDLERS='{sh(pipeline.get('max_concurrent_handlers', global_max_handlers))}'")
        # model: per-project override → global default_model → hardcoded fallback
        global_model = data.get("default_model") or "claude-sonnet-4-6"
        project_model = p.get("model") or global_model
        print(f"LOOP_AGENT_MODEL='{sh(project_model)}'")
        # allowed_authors: per-project override, falls back to global setting
        global_authors = data.get("allowed_authors") or []
        project_authors = p.get("allowed_authors") or global_authors
        authors_str = ",".join(str(a) for a in project_authors)
        print(f"ALLOWED_AUTHORS='{sh(authors_str)}'")
        # per-project agent/model overrides (empty string means "use global")
        project_agent = p.get("agent") or ""
        print(f"_PROJECT_AGENT='{sh(project_agent)}'")
        # _PROJECT_MODEL: explicit project-level 'model' key (distinct from the
        # global default_model path used above for LOOP_AGENT_MODEL).
        raw_project_model = p.get("model") or ""
        print(f"_PROJECT_MODEL='{sh(raw_project_model)}'")
        # fallback chain: serialise as newline-delimited "agent|model|cmd" records
        fallback_entries = p.get("fallback") or []
        fallback_lines = []
        for entry in fallback_entries:
            fa = entry.get("agent") or ""
            fm = entry.get("model") or ""
            fc = entry.get("cmd") or ""
            fallback_lines.append(f"{fa}|{fm}|{fc}")
        print(f"_PROJECT_FALLBACK='{sh(chr(10).join(fallback_lines))}'")
        # v1 fields
        print(f"WORKFLOW='{sh(workflow)}'")
        print(f"LOOP_LABEL_OVERRIDES='{sh(label_overrides)}'")
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
    export NAME REPO ROOT DEFAULT_BRANCH COMMIT_PREFIX DEV_VALIDATION_CMD QA_VALIDATION_CMD QA_BROWSER_URL QA_TIMEOUT_SECONDS HANDLER_TIMEOUT_SECONDS MERGE_STRATEGY AUTO_REBASE BACKEND MAX_CONCURRENT_PRS MAX_CONCURRENT_HANDLERS WORKTREE_EXTRA_PATHS LOOP_AGENT_MODEL ALLOWED_AUTHORS WORKFLOW LOOP_LABEL_OVERRIDES _PROJECT_AGENT _PROJECT_MODEL _PROJECT_FALLBACK
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
