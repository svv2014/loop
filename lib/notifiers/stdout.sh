#!/usr/bin/env bash
# lib/notifiers/stdout.sh — Print a notification to stdout with a timestamp.
# Usage: LOOP_NOTIFY="lib/notifiers/stdout.sh"

set -euo pipefail

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Loop: $1"
