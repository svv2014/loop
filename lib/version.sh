#!/usr/bin/env bash
# lib/version.sh — exposes LOOP_VERSION from the VERSION file at repo root.
# Sourced by lib/env.sh. Use $LOOP_VERSION in startup banners, --version
# output, bounty event payloads, and anywhere else the running version
# needs to be visible.

if [ -z "${LOOP_VERSION:-}" ]; then
    if [ -n "${LOOP_ROOT:-}" ] && [ -f "$LOOP_ROOT/VERSION" ]; then
        LOOP_VERSION=$(tr -d '[:space:]' < "$LOOP_ROOT/VERSION")
    else
        LOOP_VERSION="unknown"
    fi
    export LOOP_VERSION
fi
