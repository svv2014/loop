#!/usr/bin/env bash
# lib/notifiers/email.sh — Send a notification via mail(1).
# Usage: LOOP_NOTIFY="lib/notifiers/email.sh"
#   Set LOOP_NOTIFY_EMAIL to the recipient address.

set -euo pipefail

if ! command -v mail &>/dev/null; then
    echo "email.sh: mail not found in PATH, skipping notification" >&2
    exit 0
fi

if [ -z "${LOOP_NOTIFY_EMAIL:-}" ]; then
    echo "email.sh: LOOP_NOTIFY_EMAIL is not set, skipping notification" >&2
    exit 0
fi

printf '%s' "$1" | mail -s 'Loop alert' "$LOOP_NOTIFY_EMAIL"
