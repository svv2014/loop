#!/usr/bin/env bash
# lib/dep_parser.sh — shared dependency-reference parser source.
#
# Holds the Python parser as a heredoc-inlined shell variable so both
# lib/recovery.sh (issue + PR scan paths) and the bats suite can share one
# definition without introducing a .py source file (see CLAUDE.md).
#
# Usage from a python3 heredoc:
#     DEP_PARSER_PY="$_DEP_PARSER_PY" python3 - <<'PY'
#     import os
#     exec(os.environ['DEP_PARSER_PY'])  # installs extract() in scope
#     ...
#     PY
#
# Recognised forms (case-insensitive):
#   1. A `## Dependencies` section — every #N in that section is a blocker.
#   2. Natural-language phrases anywhere in the body:
#        blocked by #N        blocked-by #N
#        depends on #N        depends-on #N        depends #N
#        requires #N
#        waiting on #N        waits on #N
#        after #N             (only inline, not "after that")
#
# Excluded forms (these are the ticket's own scope, not blockers):
#   closes #N, fixes #N, resolves #N

_DEP_PARSER_PY=$(cat <<'PY'
import re

_NUM = re.compile(r"#(\d+)")

_NATURAL_PATTERNS = [
    re.compile(r"\bblocked[\s-]*by\s+#(\d+)", re.I),
    re.compile(r"\bdepends[\s-]*on\s+#(\d+)", re.I),
    re.compile(r"\bdepends\s+#(\d+)", re.I),
    re.compile(r"\brequires\s+#(\d+)", re.I),
    re.compile(r"\bwait(?:ing|s)\s+on\s+#(\d+)", re.I),
    re.compile(r"\bafter\s+#(\d+)", re.I),
]

_DEP_HEADING = re.compile(r"^##\s+Dependencies\s*$", re.I)


def _section_refs(body):
    refs = set()
    in_dep = False
    for line in body.splitlines():
        if _DEP_HEADING.match(line):
            in_dep = True
            continue
        if in_dep and re.match(r"^##", line):
            break
        if in_dep:
            for n in _NUM.findall(line):
                refs.add(int(n))
    return refs


def _natural_refs(body):
    refs = set()
    for pat in _NATURAL_PATTERNS:
        for n in pat.findall(body):
            refs.add(int(n))
    return refs


def extract(body, self_num=None):
    if not body:
        return []
    refs = _section_refs(body) | _natural_refs(body)
    if self_num is not None:
        refs.discard(int(self_num))
    return sorted(refs)
PY
)
export _DEP_PARSER_PY
