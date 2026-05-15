#!/usr/bin/env bash
# lib/scope.sh — per-issue scope fence for the dev handler.
#
# Parses scope declarations from an issue body and checks file paths against
# the declared scope. Three declaration sources (in priority order):
#   1. "## Files in scope"     — explicit allowlist (newline-delimited paths/globs)
#   2. "## Files NOT in scope" — explicit denylist (overrides allowlist)
#   3. Heuristic: "no production code" phrase — restrict to test files only
#
# If none of the above are present, all files are considered in scope and
# loop_check_scope returns 0 without printing anything.
#
# Public:
#   loop_check_scope <issue_body> <files_newline_separated>
#     Prints out-of-scope paths to stdout (one per line).
#     Returns 0 if clean (or no scope declared); 1 if any violation.

set -euo pipefail

if [ "${_LOOP_SCOPE_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_LOOP_SCOPE_LOADED=1

# loop_check_scope <issue_body> <files_newline_separated>
# Prints each out-of-scope file to stdout.
# Returns 0 (clean / no scope declared) or 1 (violations found).
loop_check_scope() {
    local issue_body="$1"
    local files="$2"

    [ -z "$files" ] && return 0

    LOOP_SCOPE_ISSUE_BODY="$issue_body" \
    LOOP_SCOPE_FILES="$files" \
    python3 <<'PY'
import fnmatch
import os
import re
import sys


def extract_section(body, header):
    """Return lines from a markdown ## section until the next ## heading."""
    pat = re.compile(
        r'^##\s+' + re.escape(header) + r'\s*$',
        re.IGNORECASE | re.MULTILINE,
    )
    m = pat.search(body)
    if not m:
        return []
    rest = body[m.end():]
    end = re.search(r'^##\s+', rest, re.MULTILINE)
    section = rest[: end.start()] if end else rest
    return [
        ln.strip()
        for ln in section.splitlines()
        if ln.strip() and not ln.strip().startswith('#')
    ]


def matches(path, patterns):
    """True when path or its basename matches any fnmatch pattern."""
    base = os.path.basename(path)
    for pat in patterns:
        if fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(base, pat):
            return True
        # "dir/*" → match anything under dir/
        if pat.endswith('/*'):
            prefix = pat[:-2]
            if path == prefix or path.startswith(prefix + '/'):
                return True
    return False


issue_body = os.environ.get('LOOP_SCOPE_ISSUE_BODY', '')
files = [f for f in os.environ.get('LOOP_SCOPE_FILES', '').splitlines() if f.strip()]

if not files:
    sys.exit(0)

allowlist = extract_section(issue_body, 'Files in scope')
denylist  = extract_section(issue_body, 'Files NOT in scope')
no_prod   = bool(re.search(r'no\s+production\s+code', issue_body, re.IGNORECASE))

# No scope declared — nothing to enforce
if not allowlist and not denylist and not no_prod:
    sys.exit(0)

TEST_PATTERNS = [
    'tests/*', 'test/*', 'spec/*', 'bats/*', '__tests__/*',
    'test_*.py', '*_test.go', '*.test.ts', '*.spec.ts',
    '*.test.js', '*.spec.js', '*.bats',
]

violations = []
for f in files:
    # Denylist overrides everything
    if denylist and matches(f, denylist):
        violations.append(f)
        continue

    # Allowlist: file must match at least one allowed pattern
    if allowlist and not matches(f, allowlist):
        violations.append(f)
        continue

    # Heuristic (no allowlist/denylist): only test files are allowed
    if no_prod and not allowlist and not denylist and not matches(f, TEST_PATTERNS):
        violations.append(f)

for v in violations:
    print(v)

sys.exit(1 if violations else 0)
PY
}
