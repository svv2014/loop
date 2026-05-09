#!/usr/bin/env bash
# lib/worktree.sh — helpers for git worktree setup used by dev / dev-rework
# handlers. Currently exposes one helper:
#
#   loop_link_worktree_extras <primary_root> <worktree_root>
#
# Symlinks each path declared in $WORKTREE_EXTRA_PATHS (newline-delimited,
# set by lib/config.sh from `dev.worktree_extra_paths` in projects.yaml)
# from the primary checkout into the freshly-created worktree at the same
# relative location.
#
# Why: projects with gitignored runtime files (ML training arrays,
# downloaded models, large fixtures) cannot run inside a vanilla worktree
# because git only carries tracked files. This makes those paths visible
# without copying them.
#
# Symlink (not copy) — keeps things fast for large directories and the
# read-only contract is documented; workers must not mutate these paths.

# loop_link_worktree_extras <primary_root> <worktree_root>
# Walk $WORKTREE_EXTRA_PATHS and symlink each entry from the primary
# checkout into the worktree. Idempotent: if the link target already exists
# the entry is skipped.
loop_link_worktree_extras() {
    local primary_root="$1" worktree_root="$2"

    [ -z "${WORKTREE_EXTRA_PATHS:-}" ] && return 0

    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        # Normalize: strip leading + trailing slashes so dirname works correctly.
        rel="${rel#/}"
        rel="${rel%/}"

        local src="${primary_root%/}/${rel}"
        local dst="${worktree_root%/}/${rel}"

        if [ ! -e "$src" ]; then
            echo "  worktree-extras: skip $rel (source not present at $src)" >&2
            continue
        fi

        # If something already exists at the worktree path (tracked file with
        # same name, or a previous run's symlink), skip rather than clobber.
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            echo "  worktree-extras: skip $rel (already exists in worktree)" >&2
            continue
        fi

        # Make sure the parent directory exists in the worktree.
        mkdir -p "$(dirname "$dst")"

        if ln -s "$src" "$dst"; then
            echo "  worktree-extras: linked $rel" >&2
        else
            echo "  worktree-extras: WARN failed to link $rel" >&2
        fi
    done <<< "$WORKTREE_EXTRA_PATHS"
}
