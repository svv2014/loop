#!/usr/bin/env bash
# update.sh — pull the latest Loop from origin, surfacing BREAKING: warnings.
#
# Usage:
#   ./scripts/update.sh              # fetch, warn on breaking changes, abort
#   ./scripts/update.sh --yes        # fetch + apply even with breaking changes
#   ./scripts/update.sh --check      # fetch, show full changelog diff, no apply
#   ./scripts/update.sh --dry-run    # same as --check (alias)
#
# Per-component: if LOOP_MONITOR_ROOT is set in loop.env and points to a git
# repo, loop-monitor's CHANGELOG.md is also scanned for BREAKING: markers.
#
# LOOP_ROOT may be overridden via env to point at a different repo root
# (used by tests; production behavior is unchanged).

set -euo pipefail

LOOP_ROOT="${LOOP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$LOOP_ROOT"

# Source loop.env so LOOP_MONITOR_ROOT (and other vars) are available.
if [ -f "$LOOP_ROOT/loop.env" ]; then
    # shellcheck source=../loop.env.example
    set +u; . "$LOOP_ROOT/loop.env"; set -u
fi

YES=false
CHECK=false

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)             YES=true;  shift ;;
        --check|--dry-run) CHECK=true; shift ;;
        -h|--help)         sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── extract BREAKING: entries from a CHANGELOG diff on stdin ─────────────────
# Prints "  <version header>\n    BREAKING: ..." blocks; empty if none found.
# Uses process substitution so python's stdin stays as the piped diff;
# `python3 - <<'PY'` would redirect stdin to the heredoc, swallowing the pipe.
_extract_breaking() {
    python3 <(cat <<'PY'
import sys, re

diff = sys.stdin.read()

added_lines = []
for line in diff.splitlines():
    if line.startswith('+') and not line.startswith('+++'):
        added_lines.append(line[1:])

added_text = '\n'.join(added_lines)

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
            results.append(f"    {b}")

print('\n'.join(results))
PY
    )
}

# ── fetch loop core ───────────────────────────────────────────────────────────
echo "[update] fetching loop core (origin/main) …"
git fetch origin main --quiet

CORE_UP_TO_DATE=false
if git diff --quiet HEAD..origin/main; then
    CORE_UP_TO_DATE=true
fi

CORE_DIFF=""
CORE_BREAKING=""
if ! $CORE_UP_TO_DATE; then
    CORE_DIFF=$(git diff HEAD..origin/main -- CHANGELOG.md 2>/dev/null || true)
    CORE_BREAKING=$(echo "$CORE_DIFF" | _extract_breaking)
fi

# ── fetch loop-monitor (optional) ────────────────────────────────────────────
MONITOR_BREAKING=""
MONITOR_DIFF=""
MONITOR_UP_TO_DATE=true  # treated as "not behind" when monitor is not configured

if [ -n "${LOOP_MONITOR_ROOT:-}" ] && [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
    echo "[update] fetching loop-monitor (${LOOP_MONITOR_ROOT}) …"
    (cd "$LOOP_MONITOR_ROOT" && git fetch origin main --quiet 2>/dev/null) || true

    if (cd "$LOOP_MONITOR_ROOT" && git diff --quiet HEAD..origin/main 2>/dev/null); then
        MONITOR_UP_TO_DATE=true
    else
        MONITOR_UP_TO_DATE=false
    fi

    if ! $MONITOR_UP_TO_DATE; then
        MONITOR_DIFF=$(cd "$LOOP_MONITOR_ROOT" && git diff HEAD..origin/main -- CHANGELOG.md 2>/dev/null || true)
        MONITOR_BREAKING=$(echo "$MONITOR_DIFF" | _extract_breaking)
    fi
fi

# ── --check: show full diffs and exit without applying ───────────────────────
if $CHECK; then
    echo ""
    echo "=== loop core changelog ==="
    if $CORE_UP_TO_DATE; then
        echo "(already up to date)"
    else
        echo "$CORE_DIFF" | grep '^+' | grep -v '^+++' | sed 's/^+//' | head -80
    fi

    if [ -n "${LOOP_MONITOR_ROOT:-}" ] && [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
        echo ""
        echo "=== loop-monitor changelog ==="
        if $MONITOR_UP_TO_DATE; then
            echo "(already up to date)"
        else
            echo "$MONITOR_DIFF" | grep '^+' | grep -v '^+++' | sed 's/^+//' | head -80
        fi
    fi

    echo ""
    COMBINED_BREAKING="${CORE_BREAKING}${MONITOR_BREAKING}"
    if [ -n "$COMBINED_BREAKING" ]; then
        echo "⚠ This update contains breaking changes:"
        echo ""
        echo "$COMBINED_BREAKING"
    else
        echo "(no breaking changes detected)"
    fi
    exit 0
fi

# ── nothing to do? ───────────────────────────────────────────────────────────
if $CORE_UP_TO_DATE && $MONITOR_UP_TO_DATE; then
    echo "[update] already up to date."
    exit 0
fi

# ── combine breaking warnings from both components ───────────────────────────
COMBINED_BREAKING=""
[ -n "$CORE_BREAKING" ]    && COMBINED_BREAKING="${COMBINED_BREAKING}[loop core]\n${CORE_BREAKING}\n"
[ -n "$MONITOR_BREAKING" ] && COMBINED_BREAKING="${COMBINED_BREAKING}[loop-monitor]\n${MONITOR_BREAKING}\n"

# ── gate on BREAKING: unless --yes ───────────────────────────────────────────
if [ -n "$COMBINED_BREAKING" ] && [ "$YES" != "true" ]; then
    echo ""
    echo "⚠ This update contains breaking changes:"
    echo ""
    printf '%b' "$COMBINED_BREAKING"
    echo ""
    echo "Re-run with --yes to apply, or --check to see the full changelog without applying."
    exit 1
fi

# ── apply ────────────────────────────────────────────────────────────────────
if ! $CORE_UP_TO_DATE; then
    echo "[update] applying loop core …"
    git merge --ff-only origin/main
    echo "[update] loop core updated to $(cat VERSION 2>/dev/null || echo unknown)"
fi

if ! $MONITOR_UP_TO_DATE && [ -n "${LOOP_MONITOR_ROOT:-}" ] && [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
    echo "[update] applying loop-monitor …"
    (cd "$LOOP_MONITOR_ROOT" && git merge --ff-only origin/main)
    echo "[update] loop-monitor updated to $(cat "${LOOP_MONITOR_ROOT}/VERSION" 2>/dev/null || echo unknown)"
fi

echo "[update] done."
