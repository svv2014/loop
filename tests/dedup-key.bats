#!/usr/bin/env bats
# tests/dedup-key.bats — covers _dedup_key in scanner/scanner.sh (issue #359).
# Verifies hash output is bare hex with no trailing whitespace/dash on both
# Linux (md5sum) and macOS (md5 -q) backends.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    # _dedup_key is defined in scanner/scanner.sh — pull it in via the
    # lib-only sourcing mode the other tests use, but since scanner.sh
    # has no such mode, just extract the function via subshell sourcing.
    eval "$(awk '/^_dedup_key\(\)/{p=1} p; p && /^}/{exit}' "$REPO_ROOT/scanner/scanner.sh")"
}

@test "_dedup_key: output has no whitespace" {
    run _dedup_key "loop.pr_review:loop-monitor:223"
    [ "$status" -eq 0 ]
    # Pure hex, no spaces, no trailing dash:
    [[ "$output" =~ ^[a-f0-9]+$ ]]
}

@test "_dedup_key: stable across calls" {
    r1=$(_dedup_key "loop.dev_issue:foo:42")
    r2=$(_dedup_key "loop.dev_issue:foo:42")
    [ "$r1" = "$r2" ]
}

@test "_dedup_key: different inputs hash differently" {
    r1=$(_dedup_key "loop.dev_issue:foo:42")
    r2=$(_dedup_key "loop.dev_issue:foo:43")
    [ "$r1" != "$r2" ]
}

@test "_dedup_key: produces valid filename (no embedded special chars)" {
    key=$(_dedup_key "loop.pr_review:org/repo-with-dashes:9999")
    # Filename must not contain space, dash-at-end, slash, or newline:
    [[ "$key" =~ ^[a-f0-9]+$ ]]
    [ "${key: -1}" != " " ]
    [ "${key: -1}" != "-" ]
}
