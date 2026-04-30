#!/usr/bin/env bash
# migrate-labels.sh — one-shot per-project deprecated→canonical label migration.
#
# Walks projects in config/projects.yaml, re-tags every open issue/PR that
# carries a deprecated alias with the canonical label, then deletes the
# deprecated label definition from the repo.
#
# Usage:
#   scripts/migrate-labels.sh --slug <s>           # one project (dry-run by default)
#   scripts/migrate-labels.sh --all                # every project
#   scripts/migrate-labels.sh --slug <s> --apply   # actually mutate
#   scripts/migrate-labels.sh --all --apply
#
# Idempotent: a second --all run after a clean migration produces zero changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_YAML="${LOOP_CONFIG:-$LOOP_ROOT/config/projects.yaml}"

TARGET_SLUG=""
ALL=false
APPLY=false

usage() {
    sed -n '1,15p' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --slug=*) TARGET_SLUG="${1#--slug=}"; shift ;;
        --slug)   TARGET_SLUG="${2:-}"; shift 2 ;;
        --all)    ALL=true; shift ;;
        --dry-run) APPLY=false; shift ;;
        --apply)  APPLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! $ALL && [ -z "$TARGET_SLUG" ]; then
    echo "error: pass --slug <s> or --all" >&2
    usage >&2
    exit 2
fi

if [ ! -f "$PROJECTS_YAML" ]; then
    echo "error: projects config not found at $PROJECTS_YAML" >&2
    exit 2
fi

# Deprecated alias → canonical name.
# Keep this list in sync with the canonical vocabulary in scripts/label-audit.sh.
DEPRECATED_TO_CANONICAL=(
    "plan:po-review"
    "build:dev"
    "needs-review:review-pending"
    "needs-qa:ready-for-qa"
    "approved:qa-pass"
    "qa-failed:qa-fail"
    "needs-rework:changes-requested"
)

canonical_for() {
    local dep="$1" entry
    for entry in "${DEPRECATED_TO_CANONICAL[@]}"; do
        if [ "${entry%%:*}" = "$dep" ]; then
            echo "${entry#*:}"
            return 0
        fi
    done
    return 1
}

# Collect target slugs.
slugs=()
if $ALL; then
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
else
    slugs=("$TARGET_SLUG")
fi

if [ ${#slugs[@]} -eq 0 ]; then
    echo "no projects found in $PROJECTS_YAML" >&2
    exit 0
fi

repo_for_slug() {
    python3 - "$PROJECTS_YAML" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
for p in data.get("projects", []) or []:
    if p.get("slug") == sys.argv[2]:
        print(p.get("repo", ""))
        break
PY
}

mode_label="dry-run"
$APPLY && mode_label="apply"

overall_rc=0

for slug in "${slugs[@]}"; do
    repo=$(repo_for_slug "$slug")
    if [ -z "$repo" ]; then
        echo "[WARN] slug '$slug' not found in $PROJECTS_YAML — skipping" >&2
        overall_rc=1
        continue
    fi

    echo "── $slug ($repo) [$mode_label] ─────────────"

    # Fetch existing label names on the repo.
    existing=$(gh label list --repo "$repo" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)

    renamed=0
    deleted=0

    for entry in "${DEPRECATED_TO_CANONICAL[@]}"; do
        dep="${entry%%:*}"
        canon="${entry#*:}"

        if ! grep -Fxq "$dep" <<<"$existing"; then
            continue
        fi

        # Find open issues/PRs still tagged with the deprecated alias.
        items_json=$(gh issue list --repo "$repo" --state open --label "$dep" --limit 500 \
                       --json number 2>/dev/null || echo "[]")
        prs_json=$(gh pr list --repo "$repo" --state open --label "$dep" --limit 500 \
                       --json number 2>/dev/null || echo "[]")

        issue_nums=$(echo "$items_json" | python3 -c 'import sys, json; [print(i["number"]) for i in json.load(sys.stdin)]' 2>/dev/null || true)
        pr_nums=$(echo "$prs_json" | python3 -c 'import sys, json; [print(i["number"]) for i in json.load(sys.stdin)]' 2>/dev/null || true)

        for n in $issue_nums; do
            echo "  rename #$n: $dep → $canon"
            if $APPLY; then
                gh issue edit "$n" --repo "$repo" --add-label "$canon" --remove-label "$dep" >/dev/null \
                    || { echo "    [WARN] failed to retag issue #$n" >&2; overall_rc=1; continue; }
            fi
            renamed=$((renamed + 1))
        done
        for n in $pr_nums; do
            echo "  rename PR #$n: $dep → $canon"
            if $APPLY; then
                gh pr edit "$n" --repo "$repo" --add-label "$canon" --remove-label "$dep" >/dev/null \
                    || { echo "    [WARN] failed to retag PR #$n" >&2; overall_rc=1; continue; }
            fi
            renamed=$((renamed + 1))
        done

        # Verify nothing still carries the deprecated label before deleting it.
        # In dry-run we can only delete safely if there were zero items to start with.
        remaining_issues="0"
        remaining_prs="0"
        if $APPLY; then
            remaining_issues=$(gh issue list --repo "$repo" --state open --label "$dep" --limit 1 \
                                  --json number --jq 'length' 2>/dev/null || echo "0")
            remaining_prs=$(gh pr list --repo "$repo" --state open --label "$dep" --limit 1 \
                                  --json number --jq 'length' 2>/dev/null || echo "0")
        else
            # In dry-run: only "safe to delete" if nothing currently uses it.
            remaining_issues=$(echo "$items_json" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
            remaining_prs=$(echo "$prs_json" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
        fi

        if [ "$remaining_issues" = "0" ] && [ "$remaining_prs" = "0" ]; then
            echo "  delete label: $dep"
            if $APPLY; then
                if gh label delete "$dep" --repo "$repo" --yes >/dev/null 2>&1; then
                    deleted=$((deleted + 1))
                else
                    echo "    [WARN] failed to delete label '$dep' (perms? still in use?)" >&2
                    overall_rc=1
                fi
            else
                deleted=$((deleted + 1))
            fi
        else
            echo "  [SKIP] label '$dep' still attached (issues=$remaining_issues prs=$remaining_prs) — not deleting"
            overall_rc=1
        fi
    done

    echo "migrate-labels slug=$slug renamed=$renamed deleted=$deleted"
done

exit "$overall_rc"
