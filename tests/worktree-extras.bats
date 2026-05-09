#!/usr/bin/env bats
# Tests for lib/worktree.sh — symlink-extras-into-worktree helper.

setup() {
    LOOP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/worktree.sh
    source "$LOOP_ROOT/lib/worktree.sh"
    PRIMARY=$(mktemp -d)
    WORKTREE=$(mktemp -d)
}

teardown() {
    rm -rf "$PRIMARY" "$WORKTREE"
}

@test "no-op when WORKTREE_EXTRA_PATHS is unset" {
    unset WORKTREE_EXTRA_PATHS
    run loop_link_worktree_extras "$PRIMARY" "$WORKTREE"
    [ "$status" -eq 0 ]
    [ -z "$(ls "$WORKTREE")" ]
}

@test "symlinks each entry from primary into worktree" {
    mkdir -p "$PRIMARY/data/processed" "$PRIMARY/models"
    touch "$PRIMARY/data/processed/X_train.npy" "$PRIMARY/models/best.pt"
    WORKTREE_EXTRA_PATHS=$'data/processed/\nmodels/'
    run loop_link_worktree_extras "$PRIMARY" "$WORKTREE"
    [ "$status" -eq 0 ]
    [ -L "$WORKTREE/data/processed" ]
    [ -L "$WORKTREE/models" ]
    [ -f "$WORKTREE/data/processed/X_train.npy" ]
}

@test "skips entries that don't exist in primary" {
    WORKTREE_EXTRA_PATHS="data/missing/"
    run loop_link_worktree_extras "$PRIMARY" "$WORKTREE"
    [ "$status" -eq 0 ]
    [ ! -e "$WORKTREE/data/missing" ]
    [[ "$output" == *"skip"* ]]
}

@test "skips entries that already exist in worktree" {
    mkdir -p "$PRIMARY/data" "$WORKTREE/data"
    echo "from-worktree" > "$WORKTREE/data/X.npy"
    echo "from-primary"  > "$PRIMARY/data/X.npy"
    WORKTREE_EXTRA_PATHS="data/X.npy"
    run loop_link_worktree_extras "$PRIMARY" "$WORKTREE"
    [ "$status" -eq 0 ]
    # Existing worktree file is preserved (not clobbered)
    [ "$(cat "$WORKTREE/data/X.npy")" = "from-worktree" ]
}

@test "creates parent directories before linking" {
    mkdir -p "$PRIMARY/deep/nested/path"
    touch "$PRIMARY/deep/nested/path/file.bin"
    WORKTREE_EXTRA_PATHS="deep/nested/path/file.bin"
    run loop_link_worktree_extras "$PRIMARY" "$WORKTREE"
    [ "$status" -eq 0 ]
    [ -L "$WORKTREE/deep/nested/path/file.bin" ]
}
