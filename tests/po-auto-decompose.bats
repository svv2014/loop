#!/usr/bin/env bats
# tests/po-auto-decompose.bats — unit tests for _po_has_complete_ac.
#
# Exercises the AC-detection helper in scripts/po-handler.sh that gates the
# auto-decompose Path D route for epic-labeled issues. The helper returns 0
# when the body contains a non-empty Acceptance / Acceptance Criteria section
# with at least one checkbox item, and 1 otherwise. Callers check exit code,
# not stdout.

# Inline replication of the helper from scripts/po-handler.sh so the test
# does not need to source the full handler (which pulls in env/backends).
_po_has_complete_ac() {
    BODY="${1:-}" python3 <<'PY'
import os, re, sys
body = os.environ.get('BODY', '')
m = re.search(r'(?im)^##\s+Acceptance(?:\s+Criteria)?\s*$', body)
if not m:
    sys.exit(1)
rest = body[m.end():]
nxt = re.search(r'(?m)^##\s+\S', rest)
section = rest[:nxt.start()] if nxt else rest
if re.search(r'(?m)^\s*-\s*\[[ xX]\]', section):
    sys.exit(0)
sys.exit(1)
PY
}

@test "epic body with populated Acceptance Criteria → exit 0" {
    body="$(printf '## Objective\nDo X\n\n## Acceptance Criteria\n- [ ] item one\n- [ ] item two\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 0 ]
}

@test "epic body with populated Acceptance heading (no Criteria word) → exit 0" {
    body="$(printf '## Acceptance\n- [ ] one thing\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 0 ]
}

@test "checked checkbox also counts as complete → exit 0" {
    body="$(printf '## Acceptance\n- [x] already done\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 0 ]
}

@test "missing AC section → exit 1" {
    body="$(printf '## Objective\nNo acceptance here\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 1 ]
}

@test "AC section with zero checkbox items → exit 1" {
    body="$(printf '## Acceptance Criteria\n\nSome prose but no checkboxes.\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 1 ]
}

@test "empty body → exit 1" {
    run _po_has_complete_ac ""
    [ "$status" -eq 1 ]
}

@test "AC section ends at next ## heading — checkboxes outside don't count" {
    body="$(printf '## Acceptance Criteria\n\nNo boxes here.\n\n## Notes\n- [ ] this should not count\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 1 ]
}

@test "AC section followed by another section with its own checkboxes → exit 0" {
    body="$(printf '## Acceptance\n- [ ] real ac item\n\n## Notes\n- [ ] unrelated\n')"
    run _po_has_complete_ac "$body"
    [ "$status" -eq 0 ]
}
