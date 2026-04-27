#!/usr/bin/env bash
# tester.sh — new name for qa-handler.sh; thin exec wrapper.
exec "$(dirname "$0")/qa-handler.sh" "$@"
