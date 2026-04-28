#!/usr/bin/env bash
# update.sh — pull the latest Loop from origin, surfacing BREAKING: warnings.
#
# Usage:
#   ./scripts/update.sh              # fetch, warn on breaking changes, abort
#   ./scripts/update.sh --yes        # fetch + apply even with breaking changes
#   ./scripts/update.sh --check      # fetch, show full changelog diff, no apply
#   ./scripts/update.sh --dry-run    # fetch only, no apply (alias for --check)

set -euo pipefail

LOOP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LOOP_ROOT"

YES=false
CHECK=false

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)       YES=true;  shift ;;
        --check|--dry-run) CHECK=true; shift ;;
        -h|--help)   sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── fetch ────────────────────────────────────────────────────────────────────
echo "[update] fetching origin/main …"
git fetch origin main --quiet

# Nothing to do?
if git diff --quiet HEAD..origin/main; then
    echo "[update] already up to date."
    exit 0
fi

# ── parse CHANGELOG diff for BREAKING: lines ─────────────────────────────────
CHANGELOG_DIFF=$(git diff HEAD..origin/main -- CHANGELOG.md 2>/dev/null || true)

_extract_breaking() {
    # For each added BREAKING: line, find the nearest preceding version header.
    python3 - <<'PY'
import sys, re

diff = sys.stdin.read()

# Collect added lines (strip leading +, skip diff header lines starting with +++)
added_lines = []
for line in diff.splitlines():
    if line.startswith('+') and not line.startswith('+++'):
        added_lines.append(line[1:])

# Reconstruct the added CHANGELOG text
added_text = '\n'.join(added_lines)

# Find version headers and their associated BREAKING: entries
version_header_re = re.compile(r'^## \[([^\]]+)\](.*?)$', re.MULTILINE)
breaking_re = re.compile(r'\bBREAKING:\s*.+', re.MULTILINE)

sections = list(version_header_re.finditer(added_text))
results = []

for i, m in enumerate(sections):
    end = sections[i+1].start() if i+1 < len(sections) else len(added_text)
    body = added_text[m.end():end]
    breakings = breaking_re.findall(body)
    if breakings:
        header = m.group(0).lstrip('#').strip()
        results.append(f"  {header}")
        for b in breakings:
            # indent continuation lines for readability
            lines = b.splitlines()
            results.append(f"    {lines[0]}")
            for extra in lines[1:]:
                results.append(f"              {extra}")

print('\n'.join(results))
PY
}

BREAKING=$(echo "$CHANGELOG_DIFF" | _extract_breaking)

# ── --check: show full diff and exit ─────────────────────────────────────────
if $CHECK; then
    echo "[update] changelog between HEAD and origin/main:"
    echo "$CHANGELOG_DIFF" | grep '^+' | grep -v '^+++' | sed 's/^+//'
    echo ""
    if [ -n "$BREAKING" ]; then
        echo "⚠ This update contains breaking changes:"
        echo "$BREAKING"
    else
        echo "(no breaking changes detected)"
    fi
    exit 0
fi

# ── gate on BREAKING: if --yes not given ─────────────────────────────────────
if [ -n "$BREAKING" ] && [ "$YES" != "true" ]; then
    echo ""
    echo "⚠ This update contains breaking changes:"
    echo ""
    echo "$BREAKING"
    echo ""
    echo "Re-run with --yes to apply, or --check to see the full changelog without applying."
    exit 1
fi

# ── apply ────────────────────────────────────────────────────────────────────
echo "[update] applying …"
git merge --ff-only origin/main

echo "[update] done. version: $(cat VERSION 2>/dev/null || echo unknown)"
