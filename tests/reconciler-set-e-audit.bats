#!/usr/bin/env bats
# tests/reconciler-set-e-audit.bats — static scan for set -e foot-guns
# in long-running reconciler/recovery functions (#212).
#
# Pattern: a function ending in `[ ... ] && cmd` returns 1 when the
# condition is false. Under `set -euo pipefail` this kills the caller.
# Today's #204 (_autopull_loop) and #212-discovered reconcile_stale_base
# both shipped this pattern. Test guards against future regressions.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# List of functions the audit applies to. Add new long-running ones here.
TARGETS=(
    "scanner/reconciler.sh:reconcile_"
    "scanner/reconciler.sh:recovery_"
    "scanner/reconciler.sh:_autopull_loop"
    "lib/recovery.sh:recovery_"
)

@test "no reconcile_/recovery_ function ends in a bare short-circuit (regression for #204, #212)" {
    local violations=""

    for target in "${TARGETS[@]}"; do
        local file="${target%%:*}"
        local prefix="${target##*:}"
        # awk extracts each function body; if the last non-blank, non-comment,
        # non-brace line ends with `&& ...` (no `|| true` etc.), flag it.
        local found
        found=$(awk -v prefix="$prefix" '
            /^[a-z_][a-z_0-9]*\(\) *\{/ {
                fname=$1; sub(/\(\) *\{/, "", fname)
                if (index(fname, prefix) == 1 || fname == prefix) {
                    inside=1; lastline=""
                    next
                }
            }
            inside && /^[^[:space:]#]/ && !/^\}/ {
                lastline=$0
            }
            inside && /^[[:space:]]*[^[:space:]#]/ && !/^\}/ {
                # capture indented non-blank, non-comment lines
                if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/) {
                    lastline=$0
                }
            }
            inside && /^\}/ {
                inside=0
                # Trim leading whitespace
                gsub(/^[[:space:]]+/, "", lastline)
                # Hazardous: ends in `&& cmd` without trailing `|| true` / `|| return`
                if (lastline ~ /&&[^|]*$/ && lastline !~ /\|\|/) {
                    print fname ": " lastline
                }
                lastline=""
            }
        ' "$REPO_ROOT/$file")

        if [ -n "$found" ]; then
            violations="${violations}${file}:\n${found}\n"
        fi
    done

    if [ -n "$violations" ]; then
        echo "set -e hazard found:"
        printf "%b" "$violations"
        return 1
    fi
}

@test "_autopull_loop has explicit return 0 (regression #204)" {
    grep -A20 "^_autopull_loop()" "$REPO_ROOT/scanner/reconciler.sh" \
        | grep -q "return 0"
}

@test "reconcile_stale_base has explicit return 0 (regression #212)" {
    awk '/^reconcile_stale_base\(\)/{flag=1} flag; /^\}/{if(flag){flag=0; exit}}' \
        "$REPO_ROOT/scanner/reconciler.sh" | tail -5 | grep -q "return 0"
}
