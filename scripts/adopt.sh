#!/usr/bin/env bash
# scripts/adopt.sh — adopt an existing repo into Loop with heuristic label mapping.
#
# Usage:
#   ./scripts/adopt.sh /path/to/existing-repo [--auto] [--slug SLUG]
#
# Reads repo labels via `gh label list`, maps them to Loop canonical labels,
# prompts operator on low/medium confidence matches (unless --auto), and writes
# a sparse labels: entry into config/projects.yaml.
#
# Read-only on the repo side: never modifies the target repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

# ── CLI parsing ───────────────────────────────────────────────────────────────

REPO_PATH=""
AUTO=false
SLUG_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)     AUTO=true; shift ;;
        --slug=*)   SLUG_OVERRIDE="${1#--slug=}"; shift ;;
        --slug)     shift; SLUG_OVERRIDE="${1:-}"; shift ;;
        -*)         echo "Unknown flag: $1" >&2; exit 1 ;;
        *)          REPO_PATH="$1"; shift ;;
    esac
done

if [ -z "$REPO_PATH" ]; then
    echo "Usage: $0 /path/to/existing-repo [--auto] [--slug SLUG]" >&2
    exit 1
fi

if [ ! -d "$REPO_PATH" ]; then
    echo "ERROR: directory not found: $REPO_PATH" >&2
    exit 1
fi

# ── Detect repo ───────────────────────────────────────────────────────────────

cd "$REPO_PATH"

GH_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
if [ -z "$GH_REPO" ]; then
    echo "ERROR: could not detect GitHub repo at $REPO_PATH" >&2
    echo "       Make sure 'gh' is authenticated and this is a GitHub-backed repo." >&2
    exit 1
fi

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")

# Derive slug from repo name if not overridden
if [ -n "$SLUG_OVERRIDE" ]; then
    SLUG="$SLUG_OVERRIDE"
else
    SLUG=$(basename "$GH_REPO" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
fi

echo ""
echo "Loop adoption mode — reading existing labels..."
echo ""
echo "Detected GitHub repo: $GH_REPO"
echo "Derived slug:         $SLUG"

# ── Fetch labels ──────────────────────────────────────────────────────────────

LABELS_JSON=$(gh label list --repo "$GH_REPO" --json name,color,description --limit 200 2>/dev/null || echo "[]")
LABEL_COUNT=$(echo "$LABELS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

echo "Found $LABEL_COUNT labels in the repo."
echo ""

# ── Heuristic matcher ─────────────────────────────────────────────────────────
# For each Loop canonical label, score each repo label and pick the best match.
# Confidence: high = exact substring match in name or description
#             medium = >=2 token overlaps between canonical tokens and label tokens
#             low = best available (1 token overlap or color hint only)
#
# Output: space-separated lines of:  canonical repo_label confidence

MAPPING_JSON=$(ADOPT_LABELS_JSON="$LABELS_JSON" python3 <<'PY'
import json, sys, os, re

CANONICALS = {
    # canonical: (match_tokens, color_hints)
    # color_hints are partial hex strings (lowercase, without #)
    "plan":         (["plan","triage","todo","backlog","ready-to-work","ready to work"], []),
    "needs-review": (["review","ready-for-review","rfr","needs-review","ready for review"], ["0075ca","fbca04","e4e669","bfd4f2"]),
    "needs-rework": (["rework","changes-requested","needs-changes","needs-fix","request-changes","changes requested"], ["e4813b","d93f0b","e99695"]),
    "needs-qa":     (["qa","ready-for-qa","test","ready-to-test","ready for qa","ready to test"], ["fbca04","e4e669","f9d0c4"]),
    "qa-pass":      (["merge","approved","ready-to-merge","ship-it","ready to merge","ship it"], ["0e8a16","2cbe4e","006b75"]),
    "qa-fail":      (["qa-fail","ci-fail","broken","failed","qa fail","ci fail"], ["b60205","ee0701","d93f0b"]),
    "blocked":      (["blocked","stuck","halted"], ["b60205","ee0701","e11d48"]),
    "done":         (["done","closed","completed"], ["0e8a16","2cbe4e","006b75"]),
}

def tokenize(s):
    """Lower-case, split on non-alphanumeric boundaries."""
    return set(re.split(r'[\s\-_/]+', s.lower().strip()))

labels = json.loads(os.environ["ADOPT_LABELS_JSON"])

results = {}  # canonical -> {repo_label, confidence, matched}

for canonical, (tokens, color_hints) in CANONICALS.items():
    best_label = None
    best_conf  = None
    best_score = -1

    canonical_tokens = tokenize(canonical)
    # also include the match tokens themselves
    all_canon_tokens = canonical_tokens.copy()
    for t in tokens:
        all_canon_tokens |= tokenize(t)

    for lbl in labels:
        name   = lbl["name"]
        color  = (lbl.get("color") or "").lower().lstrip("#")
        desc   = (lbl.get("description") or "").lower()

        name_lc = name.lower()

        # High: exact substring of canonical token list matches label name exactly
        # or the label name is a token in our match list (case-insensitive)
        high = False
        for tok in tokens:
            if tok in name_lc or name_lc in tok or tok == name_lc:
                high = True
                break
        # also high if label name matches the canonical exactly
        if name_lc == canonical:
            high = True

        label_tokens = tokenize(name) | tokenize(desc)

        overlap = len(all_canon_tokens & label_tokens)

        if high:
            score = 1000 + overlap
            conf  = "high"
        elif overlap >= 2:
            score = 100 + overlap
            conf  = "medium"
        else:
            # Color hint check
            color_match = any(hint in color for hint in color_hints)
            if overlap >= 1:
                score = 10 + (5 if color_match else 0)
                conf  = "low"
            elif color_match:
                score = 5
                conf  = "low"
            else:
                score = overlap  # 0
                conf  = "low"

        if score > best_score:
            best_score = score
            best_label = name
            best_conf  = conf

    if best_score > 0 and best_label is not None:
        results[canonical] = {"label": best_label, "confidence": best_conf}
    else:
        results[canonical] = {"label": None, "confidence": None}

print(json.dumps(results))
PY
)

# ── Display mapping ───────────────────────────────────────────────────────────
# Store the mapping in a temp file: one line per canonical, tab-separated:
#   canonical<TAB>repo_label<TAB>confidence
# Empty repo_label means no match found.

MAPPING_TSV=$(mktemp)
trap 'rm -f "$MAPPING_TSV"' EXIT

ADOPT_MAPPING_JSON="$MAPPING_JSON" python3 <<PY >> "$MAPPING_TSV"
import json, os
d = json.loads(os.environ["ADOPT_MAPPING_JSON"])
order = ["plan","needs-review","needs-rework","needs-qa","qa-pass","qa-fail","blocked","done"]
for c in order:
    e = d.get(c, {})
    lbl  = e.get("label") or ""
    conf = e.get("confidence") or ""
    print(f"{c}\t{lbl}\t{conf}")
PY

echo "Heuristic mapping (Loop canonical → your repo labels):"
echo ""

while IFS="$(printf '\t')" read -r canonical repo_label confidence; do
    if [ -z "$repo_label" ]; then
        printf "  %-15s → %-30s [missing — Loop will use canonical name]\n" \
            "$canonical" "(missing)"
    else
        suffix=""
        [ "$confidence" = "low" ]    && suffix=" — confirm"
        [ "$confidence" = "medium" ] && suffix=" — confirm"
        printf "  %-15s → %-30s [confidence: %s%s]\n" \
            "$canonical" "$repo_label" "$confidence" "$suffix"
    fi
done < "$MAPPING_TSV"

# ── Interactive confirmation ───────────────────────────────────────────────────
# In auto mode accept all. Otherwise prompt on low/medium matches.

SKIP_OVERRIDES=false

if ! $AUTO; then
    echo ""
    echo "[a]ccept all  [e]edit individual  [s]kip mapping (use canonical names)  [q]quit"
    printf "> "
    read -r CHOICE </dev/tty

    case "${CHOICE:-a}" in
        a|A|"")
            # Accept as-is
            ;;
        s|S)
            SKIP_OVERRIDES=true
            ;;
        q|Q)
            echo "Aborted."
            exit 0
            ;;
        e|E)
            # Edit individual low/medium entries — rewrite TSV in place
            EDITED_TSV=$(mktemp)
            while IFS="$(printf '\t')" read -r canonical repo_label confidence; do
                if [ "$confidence" = "low" ] || [ "$confidence" = "medium" ]; then
                    printf "  %s → '%s'  [confidence: %s]  accept? [Y/n/new-label]: " \
                        "$canonical" "$repo_label" "$confidence"
                    read -r ans </dev/tty
                    case "${ans:-Y}" in
                        n|N) repo_label="" ;;
                        Y|y|"") ;;
                        *) repo_label="$ans" ;;
                    esac
                fi
                printf '%s\t%s\t%s\n' "$canonical" "$repo_label" "$confidence"
            done < "$MAPPING_TSV" > "$EDITED_TSV"
            mv "$EDITED_TSV" "$MAPPING_TSV"
            ;;
        *)
            echo "Unknown choice; accepting all."
            ;;
    esac
fi

# ── Build sparse labels map ───────────────────────────────────────────────────
# Only include entries where repo_label differs from canonical name.

LABELS_YAML=""
if ! $SKIP_OVERRIDES; then
    while IFS="$(printf '\t')" read -r canonical repo_label _confidence; do
        [ -z "$repo_label" ] && continue
        [ "$repo_label" = "$canonical" ] && continue
        LABELS_YAML="${LABELS_YAML}      ${canonical}: ${repo_label}"$'\n'
    done < "$MAPPING_TSV"
fi

# ── Warn about unmappable (missing) canonicals ───────────────────────────────

echo ""
while IFS="$(printf '\t')" read -r canonical repo_label _confidence; do
    if [ -z "$repo_label" ]; then
        echo "WARN: canonical label '$canonical' has no match in $GH_REPO."
        echo "      To create it: gh label create '$canonical' --repo $GH_REPO --color ededed"
    fi
done < "$MAPPING_TSV"

# ── Write projects.yaml entry ─────────────────────────────────────────────────

# Allow tests (and operators) to redirect the config file.
PROJECTS_YAML="${LOOP_PROJECTS_CONFIG:-$LOOP_ROOT/config/projects.yaml}"

# Check if slug already exists — idempotent update
if grep -q "slug: ${SLUG}" "$PROJECTS_YAML" 2>/dev/null; then
    echo ""
    echo "INFO: slug '$SLUG' already exists in config/projects.yaml — skipping write."
    echo "      Edit $PROJECTS_YAML manually to update the labels: map."
else
    # Build the new entry
    COMMIT_PREFIX=$(echo "$SLUG" | tr '[:lower:]' '[:upper:]')

    NEW_ENTRY=$(cat <<ENTRY

  - name: ${GH_REPO}
    slug: ${SLUG}
    repo: ${GH_REPO}
    root: ${REPO_PATH}
    default_branch: ${DEFAULT_BRANCH}
    workflow: default
ENTRY
)

    if [ -n "$LABELS_YAML" ]; then
        NEW_ENTRY+=$'\n    labels:\n'"$LABELS_YAML"
    fi

    NEW_ENTRY+=$(cat <<ENTRY2

    dev:
      commit_prefix: ${COMMIT_PREFIX}
ENTRY2
)

    # Append to projects.yaml (create if absent)
    if [ ! -f "$PROJECTS_YAML" ]; then
        cat > "$PROJECTS_YAML" <<HEADER
# config/projects.yaml — Loop multi-project registry
# Auto-generated by scripts/adopt.sh
version: 1

projects:
HEADER
    fi

    echo "$NEW_ENTRY" >> "$PROJECTS_YAML"
    echo ""
    echo "Written to $PROJECTS_YAML"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Adoption complete for $GH_REPO (slug: $SLUG)"
if [ -n "$LABELS_YAML" ]; then
    echo "Label overrides written:"
    echo "$LABELS_YAML" | sed 's/^/  /'
else
    echo "No label overrides needed — all mappings use canonical names."
fi
echo ""
echo "Next steps:"
echo "  1. Review $PROJECTS_YAML and adjust dev.validation_cmd if needed."
echo "  2. Restart the scanner: launchctl kickstart gui/\$(id -u)/loop.scanner"
