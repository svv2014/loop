#!/usr/bin/env bats
# tests/po-decomposition-instructions.bats — coverage for #202.
#
# The fix is a prompt-engineering change: PO handler's Path D (UPGRADE TO
# EPIC) instructions now tell the agent to detect refactor-class epics
# and chain their children via "Depends on #N". We can't test agent
# behaviour (no LLM in tests), but we CAN regression-guard the prompt
# itself — if the instructions get accidentally reverted or the file
# rewrites lose them, this test fails loud.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PO_HANDLER="$REPO_ROOT/scripts/po-handler.sh"
    [ -f "$PO_HANDLER" ]
}

@test "Path D mentions HARD CAP on child count" {
    grep -q "HARD CAP" "$PO_HANDLER"
    grep -q "LOOP_PO_MAX_CHILDREN" "$PO_HANDLER"
}

@test "Path D defines REFACTOR-CLASS DETECTION" {
    grep -q "REFACTOR-CLASS DETECTION" "$PO_HANDLER"
    # The trigger phrases must be enumerated.
    grep -q "refactor / split" "$PO_HANDLER"
    grep -q "modularize" "$PO_HANDLER"
    grep -q "extract" "$PO_HANDLER"
}

@test "Path D mandates 'Depends on #N' chaining for refactor-class epics" {
    grep -q "Depends on #N" "$PO_HANDLER"
    grep -q "chain the children" "$PO_HANDLER"
}

@test "Path D references the dep-parser / recovery module the chain depends on" {
    grep -q "recovery_check_dependencies" "$PO_HANDLER"
    grep -q "dep_parser" "$PO_HANDLER"
}

@test "Path D documents the DISJOINT-FILE escape hatch" {
    grep -q "DISJOINT-FILE" "$PO_HANDLER"
    grep -q "when in doubt assume overlap" "$PO_HANDLER"
}

@test "Path D's evidence section cites the loop-monitor incidents" {
    grep -q "loop-monitor#5" "$PO_HANDLER"
    grep -q "29 comments" "$PO_HANDLER"
}
