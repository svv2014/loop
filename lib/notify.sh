#!/usr/bin/env bash
# lib/notify.sh — loop_notify() helper; evaluates LOOP_NOTIFY command fragment.
# Sourced by all handlers. No-ops silently when LOOP_NOTIFY is unset or empty.

loop_notify() {
    [ -n "${LOOP_NOTIFY:-}" ] && eval "$LOOP_NOTIFY" "$1" || true
}
