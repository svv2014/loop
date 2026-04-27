#!/usr/bin/env bash
# builder.sh — new name for dev-handler.sh; thin exec wrapper.
exec "$(dirname "$0")/dev-handler.sh" "$@"
