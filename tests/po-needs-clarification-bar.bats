#!/usr/bin/env bats
# tests/po-needs-clarification-bar.bats — coverage for the tightened
# needs-clarification bar in the PO grooming prompt.
#
# Background: PO over-applied 'needs-clarification' to well-specified issues
# (8 loop-monitor issues in one night with full AC/scope already in the body).
# The prompt now defaults to writing the spec when ANY structure is present,
# and reserves needs-clarification for genuinely actionable-less issues.
# These tests regression-guard the prompt language so accidental rewrites
# can't silently revert the bar.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PO_HANDLER="$REPO_ROOT/scripts/po-handler.sh"
    [ -f "$PO_HANDLER" ]
}

@test "prompt declares BAR FOR needs-clarification block" {
    grep -q "BAR FOR needs-clarification" "$PO_HANDLER"
}

@test "prompt frames needs-clarification as LAST RESORT" {
    grep -q "LAST RESORT" "$PO_HANDLER"
}

@test "prompt enumerates positive WRITE-THE-SPEC rubric (sections, repro, paths)" {
    grep -q '"Acceptance Criteria"' "$PO_HANDLER"
    grep -q '"Out of scope"' "$PO_HANDLER"
    grep -q "bug reproduction steps" "$PO_HANDLER"
    grep -q "specific file paths" "$PO_HANDLER"
}

@test "prompt enumerates negative needs-clarification rubric" {
    grep -q "one-liner with no actionable detail" "$PO_HANDLER"
    grep -q "asks a question rather than describes work" "$PO_HANDLER"
    grep -q "mutually contradictory" "$PO_HANDLER"
    grep -q "unspecified prior decision" "$PO_HANDLER"
}

@test "prompt tells PO to prefer path A under uncertainty" {
    grep -q "prefer" "$PO_HANDLER"
    grep -q "path A" "$PO_HANDLER"
}

@test "Path E references the BAR block" {
    grep -q "E - NEEDS CLARIFICATION (LAST RESORT" "$PO_HANDLER"
}
