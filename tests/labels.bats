#!/usr/bin/env bats
# tests/labels.bats — verify lib/labels.sh canonical set + deprecated alias map.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/labels.sh
    source "$REPO_ROOT/lib/labels.sh"
}

@test "canonical set has the expected 14 names" {
    [ "${#LOOP_CANONICAL_LABELS[@]}" -eq 14 ]
    local expected="needs-po in-po needs-dev in-dev needs-review in-review needs-qa qa-pass qa-fail blocked done external-pr external-review-pass external-review-fail"
    local actual="${LOOP_CANONICAL_LABELS[*]}"
    [ "$actual" = "$expected" ]
}

@test "convenience scalars match the canonical names" {
    [ "$LOOP_LABEL_NEEDS_PO"              = "needs-po" ]
    [ "$LOOP_LABEL_IN_PO"                 = "in-po" ]
    [ "$LOOP_LABEL_NEEDS_DEV"             = "needs-dev" ]
    [ "$LOOP_LABEL_IN_DEV"                = "in-dev" ]
    [ "$LOOP_LABEL_NEEDS_REVIEW"          = "needs-review" ]
    [ "$LOOP_LABEL_IN_REVIEW"             = "in-review" ]
    [ "$LOOP_LABEL_NEEDS_QA"              = "needs-qa" ]
    [ "$LOOP_LABEL_QA_PASS"               = "qa-pass" ]
    [ "$LOOP_LABEL_QA_FAIL"               = "qa-fail" ]
    [ "$LOOP_LABEL_BLOCKED"               = "blocked" ]
    [ "$LOOP_LABEL_DONE"                  = "done" ]
    [ "$LOOP_LABEL_EXTERNAL_PR"           = "external-pr" ]
    [ "$LOOP_LABEL_EXTERNAL_REVIEW_PASS"  = "external-review-pass" ]
    [ "$LOOP_LABEL_EXTERNAL_REVIEW_FAIL"  = "external-review-fail" ]
}

@test "every deprecated alias resolves to a canonical label" {
    local alias canonical
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        canonical=$(loop_canonical_label "$alias")
        run loop_is_canonical_label "$canonical"
        [ "$status" -eq 0 ] || {
            echo "alias '$alias' resolved to non-canonical '$canonical'" >&2
            return 1
        }
    done < <(loop_deprecated_aliases)
}

@test "deprecated aliases match the spec" {
    [ "$(loop_canonical_label po-review)"          = "needs-po" ]
    [ "$(loop_canonical_label dev)"                = "needs-dev" ]
    [ "$(loop_canonical_label plan)"               = "needs-dev" ]
    [ "$(loop_canonical_label in-progress)"        = "needs-dev" ]
    [ "$(loop_canonical_label review-pending)"     = "needs-review" ]
    [ "$(loop_canonical_label ready-for-qa)"       = "needs-qa" ]
    [ "$(loop_canonical_label needs-rework)"       = "needs-dev" ]
    [ "$(loop_canonical_label changes-requested)"  = "needs-dev" ]
    [ "$(loop_canonical_label in-rework)"          = "in-dev" ]
}

@test "loop_canonical_label echoes unknown names unchanged" {
    [ "$(loop_canonical_label some-random-label)" = "some-random-label" ]
}

@test "loop_canonical_label echoes canonical names unchanged" {
    local l
    for l in "${LOOP_CANONICAL_LABELS[@]}"; do
        [ "$(loop_canonical_label "$l")" = "$l" ]
    done
}

@test "loop_is_canonical_label distinguishes canonical from deprecated" {
    run loop_is_canonical_label needs-review
    [ "$status" -eq 0 ]
    run loop_is_canonical_label review-pending
    [ "$status" -ne 0 ]
}

@test "loop_is_deprecated_label flags every alias and rejects canonicals" {
    local alias l
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        run loop_is_deprecated_label "$alias"
        [ "$status" -eq 0 ]
    done < <(loop_deprecated_aliases)
    for l in "${LOOP_CANONICAL_LABELS[@]}"; do
        run loop_is_deprecated_label "$l"
        [ "$status" -ne 0 ]
    done
}

@test "loop_deprecated_aliases_for lists all aliases pointing at a canonical" {
    local out
    out=$(loop_deprecated_aliases_for needs-dev | sort | tr '\n' ' ')
    [[ "$out" == *"dev"* ]]
    [[ "$out" == *"plan"* ]]
    [[ "$out" == *"in-progress"* ]]
    [[ "$out" == *"needs-rework"* ]]
    [[ "$out" == *"changes-requested"* ]]
}

@test "lib/labels.sh is idempotent when re-sourced" {
    source "$REPO_ROOT/lib/labels.sh"
    source "$REPO_ROOT/lib/labels.sh"
    [ "${#LOOP_CANONICAL_LABELS[@]}" -eq 14 ]
}
