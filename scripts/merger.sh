#!/usr/bin/env bash
# merger.sh — new name for merge-handler.sh; thin exec wrapper.
exec "$(dirname "$0")/merge-handler.sh" "$@"
