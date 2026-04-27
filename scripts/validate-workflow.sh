#!/usr/bin/env bash
# validate-workflow.sh — validate a workflow YAML file against schema v1.
#
# Usage:
#   ./scripts/validate-workflow.sh config/workflows/default.yaml
#   ./scripts/validate-workflow.sh                                  # validates all *.yaml under config/workflows/
#
# Exit 0 if all files validate; non-zero if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/workflow.sh
source "$LOOP_ROOT/lib/workflow.sh"

if [ $# -eq 0 ]; then
    set -- "$LOOP_ROOT"/config/workflows/*.yaml
fi

failed=0
for path in "$@"; do
    if loop_workflow_validate "$path"; then
        echo "[ok]   $path"
    else
        echo "[fail] $path" >&2
        failed=$((failed + 1))
    fi
done

[ "$failed" -eq 0 ]
