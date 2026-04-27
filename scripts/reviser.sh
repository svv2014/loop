#!/usr/bin/env bash
# reviser.sh — new name for dev-rework-handler.sh; thin exec wrapper.
exec "$(dirname "$0")/dev-rework-handler.sh" "$@"
