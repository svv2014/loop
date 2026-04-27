#!/usr/bin/env bash
# reviewer.sh — new name for review-handler.sh; thin exec wrapper.
exec "$(dirname "$0")/review-handler.sh" "$@"
