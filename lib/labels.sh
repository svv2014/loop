#!/usr/bin/env bash
# shellcheck disable=SC2034
# lib/labels.sh — canonical Loop label vocabulary + deprecated alias map.
#
# Single source of truth for the loop pipeline label names. Handlers, the
# scanner, and reconciler source this file and reference the LOOP_LABEL_*
# constants instead of hardcoding string literals. Workflow YAMLs may still
# remap canonical names per project via lib/workflow.sh::loop_label_for, but
# the canonical names themselves live here.
#
# Public surface:
#   LOOP_CANONICAL_LABELS         — array of the canonical label names
#   LOOP_DEPRECATED_ALIAS_MAP     — newline-separated "<alias> <canonical>" pairs
#   LOOP_LABEL_<NAME>             — convenience scalar per canonical name
#   LOOP_LABEL_DEPRECATED_<NAME>  — convenience scalar per deprecated alias
#   loop_canonical_label <name>   — resolve any name to its canonical form
#   loop_is_canonical_label <n>   — exit 0 if <n> is in the canonical set
#   loop_is_deprecated_label <n>  — exit 0 if <n> is in the alias map
#   loop_deprecated_aliases       — list every deprecated alias name
#   loop_deprecated_aliases_for <canonical>  — list aliases that map to it
#
# Bash 3.x compatible (no associative arrays).

# Idempotent: re-sourcing must not redeclare arrays / re-run side effects.
if [ "${_LOOP_LABELS_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_LOOP_LABELS_LOADED=1

# Canonical label set (order is the rough pipeline progression).
LOOP_CANONICAL_LABELS=(
    needs-po
    in-po
    needs-dev
    in-dev
    needs-review
    in-review
    needs-qa
    qa-pass
    qa-fail
    blocked
    "done"
)

# Convenience scalars — handlers reference these instead of string literals.
LOOP_LABEL_NEEDS_PO=needs-po
LOOP_LABEL_IN_PO=in-po
LOOP_LABEL_NEEDS_DEV=needs-dev
LOOP_LABEL_IN_DEV=in-dev
LOOP_LABEL_NEEDS_REVIEW=needs-review
LOOP_LABEL_IN_REVIEW=in-review
LOOP_LABEL_NEEDS_QA=needs-qa
LOOP_LABEL_QA_PASS=qa-pass
LOOP_LABEL_QA_FAIL=qa-fail
LOOP_LABEL_BLOCKED=blocked
LOOP_LABEL_DONE="done"

# Deprecated label aliases — names still used by older workflows / GitHub
# repos / PR bodies. Each maps to its canonical replacement. Handlers may
# still need to *strip* these labels off issues/PRs during migration, so we
# expose them as named scalars too.
#
# Stored as a newline-separated "<alias> <canonical>" string for bash 3.x
# compatibility (no associative arrays). Use loop_canonical_label /
# loop_deprecated_aliases_for to query.
LOOP_DEPRECATED_ALIAS_MAP="po-review needs-po
dev needs-dev
plan needs-dev
in-progress needs-dev
review-pending needs-review
ready-for-qa needs-qa
needs-rework needs-dev
changes-requested needs-dev
in-rework in-dev"

LOOP_LABEL_DEPRECATED_PO_REVIEW=po-review
LOOP_LABEL_DEPRECATED_DEV=dev
LOOP_LABEL_DEPRECATED_PLAN=plan
LOOP_LABEL_DEPRECATED_IN_PROGRESS=in-progress
LOOP_LABEL_DEPRECATED_REVIEW_PENDING=review-pending
LOOP_LABEL_DEPRECATED_READY_FOR_QA=ready-for-qa
LOOP_LABEL_DEPRECATED_NEEDS_REWORK=needs-rework
LOOP_LABEL_DEPRECATED_CHANGES_REQUESTED=changes-requested
LOOP_LABEL_DEPRECATED_IN_REWORK=in-rework

# loop_canonical_label <name>
# Echo the canonical form for <name>. If <name> is already canonical (or
# unknown), it is echoed unchanged.
loop_canonical_label() {
    local name="${1:-}" alias canonical
    while IFS=' ' read -r alias canonical; do
        [ -z "$alias" ] && continue
        if [ "$alias" = "$name" ]; then
            printf '%s\n' "$canonical"
            return 0
        fi
    done <<EOF
$LOOP_DEPRECATED_ALIAS_MAP
EOF
    printf '%s\n' "$name"
}

# loop_is_canonical_label <name>
loop_is_canonical_label() {
    local name="${1:-}" l
    for l in "${LOOP_CANONICAL_LABELS[@]}"; do
        [ "$l" = "$name" ] && return 0
    done
    return 1
}

# loop_is_deprecated_label <name>
loop_is_deprecated_label() {
    local name="${1:-}" alias canonical
    while IFS=' ' read -r alias canonical; do
        [ -z "$alias" ] && continue
        [ "$alias" = "$name" ] && return 0
    done <<EOF
$LOOP_DEPRECATED_ALIAS_MAP
EOF
    return 1
}

# loop_deprecated_aliases — print every deprecated alias name, one per line.
loop_deprecated_aliases() {
    local alias canonical
    while IFS=' ' read -r alias canonical; do
        [ -z "$alias" ] && continue
        printf '%s\n' "$alias"
    done <<EOF
$LOOP_DEPRECATED_ALIAS_MAP
EOF
}

# loop_deprecated_aliases_for <canonical>
# Print, one per line, every deprecated alias that maps to <canonical>.
loop_deprecated_aliases_for() {
    local target="${1:-}" alias canonical
    while IFS=' ' read -r alias canonical; do
        [ -z "$alias" ] && continue
        [ "$canonical" = "$target" ] && printf '%s\n' "$alias"
    done <<EOF
$LOOP_DEPRECATED_ALIAS_MAP
EOF
}
