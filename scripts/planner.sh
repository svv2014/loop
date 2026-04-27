#!/usr/bin/env bash
# planner.sh — new name for po-handler.sh; thin exec wrapper.
exec "$(dirname "$0")/po-handler.sh" "$@"
