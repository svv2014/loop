#!/usr/bin/env bash
# label-audit.sh — report non-standard labels on managed project repos.
#
# Usage:
#   scripts/label-audit.sh                 # audit all projects in projects.yaml
#   scripts/label-audit.sh --slug <slug>   # audit one project
#   scripts/label-audit.sh --fix           # also create any missing canonical labels
#
# Exit codes:
#   0 — all projects have the full canonical label set, no non-standard labels found
#   1 — at least one problem detected (missing or non-standard labels)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_YAML="$LOOP_ROOT/config/projects.yaml"

TARGET_SLUG=""
FIX_MODE=false

for arg in "$@"; do
    case "$arg" in
        --slug=*) TARGET_SLUG="${arg#--slug=}" ;;
        --slug)   shift; TARGET_SLUG="${1:-}" ;;
        --fix)    FIX_MODE=true ;;
        -h|--help)
            sed -n '1,10p' "$0"
            exit 0
            ;;
    esac
done

# Canonical pipeline labels (name|color|description)
CANONICAL_LABELS=(
    "po-review|1D76DB|PO agent expands rough idea into full spec"
    "dev|0075CA|Issue ready for automated dev cycle"
    "in-progress|FFA500|Currently being worked on by dev agent"
    "in-review|6A5ACD|Reviewer is looking at it"
    "review-pending|9370DB|PR open, waiting for automated review"
    "ready-for-qa|FFD700|Approved, needs QA validation"
    "qa-pass|32CD32|QA passed, ready to merge"
    "qa-fail|DC143C|QA failed, back to dev for rework"
    "changes-requested|FFA07A|Reviewer requested changes"
    "blocked|8B0000|Failed 3x, needs human"
    "needs-clarification|FF69B4|Dev hit ambiguity"
    "done|006400|Merged and closed"
)

# Build lookup set of canonical names (and known aliases added by additive label rename)
KNOWN_LABELS=(
    po-review dev plan in-progress build
    review-pending needs-review in-review
    ready-for-qa needs-qa
    qa-pass approved
    qa-fail qa-failed
    changes-requested needs-rework
    blocked needs-clarification "done"
    bug enhancement question documentation duplicate wontfix invalid
)

is_known() {
    local label="$1"
    local k
    for k in "${KNOWN_LABELS[@]}"; do
        [ "$k" = "$label" ] && return 0
    done
    return 1
}

# Collect slugs to audit
slugs=()
if [ -n "$TARGET_SLUG" ]; then
    slugs=("$TARGET_SLUG")
else
    while IFS= read -r s; do
        [ -n "$s" ] && slugs+=("$s")
    done < <(python3 - "$PROJECTS_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
for p in data.get("projects", []) or []:
    s = p.get("slug")
    if s:
        print(s)
PY
)
fi

if [ ${#slugs[@]} -eq 0 ]; then
    echo "No projects found in $PROJECTS_YAML" >&2
    exit 0
fi

overall_ok=true

for slug in "${slugs[@]}"; do
    repo=$(python3 - "$PROJECTS_YAML" "$slug" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
for p in data.get("projects", []) or []:
    if p.get("slug") == sys.argv[2]:
        print(p.get("repo", ""))
        break
PY
)
    if [ -z "$repo" ]; then
        echo "[WARN] slug '$slug' not found in $PROJECTS_YAML — skipping" >&2
        continue
    fi

    echo "── $slug ($repo) ──────────────────────────"

    # Fetch all labels from GitHub
    existing_labels=()
    while IFS= read -r lname; do
        [ -n "$lname" ] && existing_labels+=("$lname")
    done < <(gh label list --repo "$repo" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)

    # Find missing canonical labels
    missing=()
    for spec in "${CANONICAL_LABELS[@]}"; do
        cname="${spec%%|*}"
        found=false
        for el in "${existing_labels[@]}"; do
            [ "$el" = "$cname" ] && found=true && break
        done
        $found || missing+=("$cname")
    done

    # Find non-standard labels (not in known set)
    nonstandard=()
    for el in "${existing_labels[@]}"; do
        is_known "$el" || nonstandard+=("$el")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        overall_ok=false
        echo "  [missing]"
        for m in "${missing[@]}"; do
            echo "    - $m"
            if $FIX_MODE; then
                spec=""
                for s in "${CANONICAL_LABELS[@]}"; do
                    [ "${s%%|*}" = "$m" ] && spec="$s" && break
                done
                rest="${spec#*|}"
                color="${rest%%|*}"
                desc="${rest#*|}"
                if gh label create "$m" --repo "$repo" --color "$color" --description "$desc" 2>/dev/null; then
                    echo "      → created"
                else
                    echo "      → already exists or error" >&2
                fi
            fi
        done
    fi

    if [ ${#nonstandard[@]} -gt 0 ]; then
        overall_ok=false
        echo "  [non-standard]"
        for ns in "${nonstandard[@]}"; do
            echo "    - $ns"
        done
    fi

    if [ ${#missing[@]} -eq 0 ] && [ ${#nonstandard[@]} -eq 0 ]; then
        echo "  [ok] all canonical labels present, no non-standard labels"
    fi
    echo
done

if $overall_ok; then
    exit 0
else
    echo "Issues found. Run with --fix to create missing canonical labels." >&2
    exit 1
fi
