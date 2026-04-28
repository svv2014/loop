#!/usr/bin/env bash
# update.sh — pull the latest Loop from origin, surfacing BREAKING: warnings.
#
# Usage:
#   ./scripts/update.sh              # fetch, warn on breaking changes, abort
#   ./scripts/update.sh --yes        # fetch + apply even with breaking changes
#   ./scripts/update.sh --check      # fetch, show full changelog diff, no apply
#   ./scripts/update.sh --dry-run    # same as --check (alias)
#   ./scripts/update.sh --core-only  # pull loop core only, skip monitor
#   ./scripts/update.sh --monitor-only  # pull loop-monitor only and restart it
#   ./scripts/update.sh --to <tag>   # checkout a specific tag instead of pulling
#   ./scripts/update.sh --rollback   # revert to the SHA recorded before the last update
#
# Per-component: if LOOP_MONITOR_ROOT is set (or ~/projects/loop-monitor exists)
# and points to a git repo, loop-monitor is also updated and restarted.
#
# LOOP_ROOT may be overridden via env to point at a different repo root
# (used by tests; production behavior is unchanged).

set -euo pipefail

LOOP_ROOT="${LOOP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$LOOP_ROOT"

# Source loop.env so LOOP_MONITOR_ROOT (and other vars) are available.
if [ -f "$LOOP_ROOT/loop.env" ]; then
    # shellcheck source=../loop.env.example
    set +u; . "$LOOP_ROOT/loop.env"; set -u
fi

# Resolve monitor root: explicit env var, else ~/projects/loop-monitor.
LOOP_MONITOR_ROOT="${LOOP_MONITOR_ROOT:-$HOME/projects/loop-monitor}"

YES=false
CHECK=false
CORE_ONLY=false
MONITOR_ONLY=false
TO_TAG=""
ROLLBACK=false

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)             YES=true;  shift ;;
        --check|--dry-run) CHECK=true; shift ;;
        --core-only)       CORE_ONLY=true; shift ;;
        --monitor-only)    MONITOR_ONLY=true; shift ;;
        --to)              shift; TO_TAG="${1:-}"; [ -n "$TO_TAG" ] || { echo "--to requires a tag argument" >&2; exit 2; }; shift ;;
        --rollback)        ROLLBACK=true; shift ;;
        -h|--help)         sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── update history log ────────────────────────────────────────────────────────
LOOP_UPDATE_LOG="${LOOP_UPDATE_LOG:-$HOME/.loop/update-history.log}"

_record_update() {
    local repo="$1" from_sha="$2" to_sha="$3"
    mkdir -p "$(dirname "$LOOP_UPDATE_LOG")"
    printf '%s %s %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$repo" "$from_sha" "$to_sha" \
        >> "$LOOP_UPDATE_LOG"
}

# ── extract BREAKING: entries from a CHANGELOG diff on stdin ─────────────────
# Prints "  <version header>\n    BREAKING: ..." blocks; empty if none found.
# Uses process substitution so python's stdin stays as the piped diff;
# `python3 - <<'PY'` would redirect stdin to the heredoc, swallowing the pipe.
_extract_breaking() {
    python3 <(cat <<'PY'
import sys, re

diff = sys.stdin.read()

added_lines = []
for line in diff.splitlines():
    if line.startswith('+') and not line.startswith('+++'):
        added_lines.append(line[1:])

added_text = '\n'.join(added_lines)

version_header_re = re.compile(r'^## \[([^\]]+)\](.*?)$', re.MULTILINE)
breaking_re = re.compile(r'\bBREAKING:\s*.+', re.MULTILINE)

sections = list(version_header_re.finditer(added_text))
results = []

for i, m in enumerate(sections):
    end = sections[i+1].start() if i+1 < len(sections) else len(added_text)
    body = added_text[m.end():end]
    breakings = breaking_re.findall(body)
    if breakings:
        header = m.group(0).lstrip('#').strip()
        results.append(f"  {header}")
        for b in breakings:
            results.append(f"    {b}")

print('\n'.join(results))
PY
    )
}

# ── restart loop-monitor service after update ────────────────────────────────
_restart_monitor() {
    if [[ "$(uname)" == "Darwin" ]]; then
        launchctl kickstart -k "gui/$(id -u)/com.loop.loop-monitor" 2>/dev/null \
            && echo "[update] loop-monitor service restarted." \
            || echo "[update] note: could not restart loop-monitor via launchctl (service may not be loaded)."
    else
        echo "[update] note: loop-monitor restart not automated on Linux — restart it manually if needed."
    fi
}

# ── --rollback ────────────────────────────────────────────────────────────────
if $ROLLBACK; then
    if [ ! -f "$LOOP_UPDATE_LOG" ]; then
        echo "[update] no update history found at $LOOP_UPDATE_LOG" >&2
        exit 1
    fi

    last_entry="$(tail -n 1 "$LOOP_UPDATE_LOG")"
    if [ -z "$last_entry" ]; then
        echo "[update] update history is empty" >&2
        exit 1
    fi

    rb_timestamp="$(printf '%s' "$last_entry" | awk '{print $1}')"
    rb_repo="$(printf '%s' "$last_entry" | awk '{print $2}')"
    rb_from_sha="$(printf '%s' "$last_entry" | awk '{print $3}')"

    echo "[update] rolling back $rb_repo to $rb_from_sha (recorded at $rb_timestamp)"

    if [ "$rb_repo" = "loop-core" ]; then
        git checkout "$rb_from_sha"
        echo "[update] loop core rolled back to $rb_from_sha"
    elif [ "$rb_repo" = "loop-monitor" ]; then
        if [ ! -d "${LOOP_MONITOR_ROOT}/.git" ]; then
            echo "[update] LOOP_MONITOR_ROOT not a git repo; cannot roll back monitor" >&2
            exit 1
        fi
        (cd "$LOOP_MONITOR_ROOT" && git checkout "$rb_from_sha")
        echo "[update] loop-monitor rolled back to $rb_from_sha"
        _restart_monitor
    else
        echo "[update] unknown repo in history: $rb_repo" >&2
        exit 1
    fi

    echo "[update] rollback complete."
    exit 0
fi

# ── --to <tag>: tag-pinned update path ───────────────────────────────────────
if [ -n "$TO_TAG" ]; then
    if ! $MONITOR_ONLY; then
        echo "[update] pinning loop core to tag $TO_TAG …"
        git fetch --tags --quiet
        CORE_FROM_SHA="$(git rev-parse HEAD)"
        CORE_TO_SHA="$(git rev-parse "refs/tags/${TO_TAG}" 2>/dev/null || git rev-parse "$TO_TAG")"
        if [ "$CORE_FROM_SHA" = "$CORE_TO_SHA" ]; then
            echo "[update] loop core already at $TO_TAG"
        else
            _record_update "loop-core" "$CORE_FROM_SHA" "$CORE_TO_SHA"
            git checkout "$TO_TAG"
            echo "[update] loop core updated to tag $TO_TAG ($(cat VERSION 2>/dev/null || echo unknown))"
        fi
    fi

    if ! $CORE_ONLY && [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
        echo "[update] pinning loop-monitor to tag $TO_TAG …"
        (cd "$LOOP_MONITOR_ROOT" && git fetch --tags --quiet)
        MON_FROM_SHA="$(cd "$LOOP_MONITOR_ROOT" && git rev-parse HEAD)"
        MON_TO_SHA="$(cd "$LOOP_MONITOR_ROOT" && \
            git rev-parse "refs/tags/${TO_TAG}" 2>/dev/null || \
            cd "$LOOP_MONITOR_ROOT" && git rev-parse "$TO_TAG")"
        if [ "$MON_FROM_SHA" = "$MON_TO_SHA" ]; then
            echo "[update] loop-monitor already at $TO_TAG"
        else
            _record_update "loop-monitor" "$MON_FROM_SHA" "$MON_TO_SHA"
            (cd "$LOOP_MONITOR_ROOT" && git checkout "$TO_TAG")
            echo "[update] loop-monitor updated to tag $TO_TAG ($(cat "${LOOP_MONITOR_ROOT}/VERSION" 2>/dev/null || echo unknown))"
            _restart_monitor
        fi
    fi

    echo "[update] done."
    exit 0
fi

# ── fetch loop core ───────────────────────────────────────────────────────────
CORE_UP_TO_DATE=true
CORE_DIFF=""
CORE_BREAKING=""
CORE_VERSION_BEFORE=""

if ! $MONITOR_ONLY; then
    echo "[update] fetching loop core (origin/main) …"
    CORE_VERSION_BEFORE="$(cat "$LOOP_ROOT/VERSION" 2>/dev/null || echo unknown)"
    git fetch origin main --quiet

    CORE_UP_TO_DATE=false
    if git diff --quiet HEAD..origin/main; then
        CORE_UP_TO_DATE=true
    fi

    if ! $CORE_UP_TO_DATE; then
        CORE_DIFF=$(git diff HEAD..origin/main -- CHANGELOG.md 2>/dev/null || true)
        CORE_BREAKING=$(echo "$CORE_DIFF" | _extract_breaking)
    fi
fi

# ── fetch loop-monitor (optional) ────────────────────────────────────────────
MONITOR_BREAKING=""
MONITOR_DIFF=""
MONITOR_UP_TO_DATE=true  # treated as "not behind" when monitor is not configured
MONITOR_VERSION_BEFORE=""

if ! $CORE_ONLY && [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
    echo "[update] fetching loop-monitor (${LOOP_MONITOR_ROOT}) …"
    MONITOR_VERSION_BEFORE="$(cat "${LOOP_MONITOR_ROOT}/VERSION" 2>/dev/null || echo unknown)"
    (cd "$LOOP_MONITOR_ROOT" && git fetch origin main --quiet 2>/dev/null) || true

    if (cd "$LOOP_MONITOR_ROOT" && git diff --quiet HEAD..origin/main 2>/dev/null); then
        MONITOR_UP_TO_DATE=true
    else
        MONITOR_UP_TO_DATE=false
    fi

    if ! $MONITOR_UP_TO_DATE; then
        MONITOR_DIFF=$(cd "$LOOP_MONITOR_ROOT" && git diff HEAD..origin/main -- CHANGELOG.md 2>/dev/null || true)
        MONITOR_BREAKING=$(echo "$MONITOR_DIFF" | _extract_breaking)
    fi
fi

# ── --check/--dry-run: show full diffs and exit without applying ──────────────
if $CHECK; then
    echo ""
    echo "=== loop core changelog ==="
    if $CORE_UP_TO_DATE; then
        echo "(already up to date)"
    else
        echo "$CORE_DIFF" | grep '^+' | grep -v '^+++' | sed 's/^+//' | head -80
    fi

    if [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
        echo ""
        echo "=== loop-monitor changelog ==="
        if $MONITOR_UP_TO_DATE; then
            echo "(already up to date)"
        else
            echo "$MONITOR_DIFF" | grep '^+' | grep -v '^+++' | sed 's/^+//' | head -80
        fi
    fi

    echo ""
    COMBINED_BREAKING="${CORE_BREAKING}${MONITOR_BREAKING}"
    if [ -n "$COMBINED_BREAKING" ]; then
        echo "⚠ This update contains breaking changes:"
        echo ""
        echo "$COMBINED_BREAKING"
    else
        echo "(no breaking changes detected)"
    fi
    exit 0
fi

# ── nothing to do? ───────────────────────────────────────────────────────────
if $CORE_UP_TO_DATE && $MONITOR_UP_TO_DATE; then
    echo "[update] already up to date."
    exit 0
fi

# ── combine breaking warnings from both components ───────────────────────────
COMBINED_BREAKING=""
[ -n "$CORE_BREAKING" ]    && COMBINED_BREAKING="${COMBINED_BREAKING}[loop core]\n${CORE_BREAKING}\n"
[ -n "$MONITOR_BREAKING" ] && COMBINED_BREAKING="${COMBINED_BREAKING}[loop-monitor]\n${MONITOR_BREAKING}\n"

# ── gate on BREAKING: unless --yes ───────────────────────────────────────────
if [ -n "$COMBINED_BREAKING" ] && [ "$YES" != "true" ]; then
    echo ""
    echo "⚠ This update contains breaking changes:"
    echo ""
    printf '%b' "$COMBINED_BREAKING"
    echo ""
    echo "Re-run with --yes to apply, or --check to see the full changelog without applying."
    exit 1
fi

# ── apply ────────────────────────────────────────────────────────────────────
if ! $CORE_UP_TO_DATE; then
    CORE_FROM_SHA="$(git rev-parse HEAD)"
    echo "[update] applying loop core …"
    echo "[update] loop core: ${CORE_VERSION_BEFORE} → applying …"
    git merge --ff-only origin/main
    CORE_TO_SHA="$(git rev-parse HEAD)"
    _record_update "loop-core" "$CORE_FROM_SHA" "$CORE_TO_SHA"
    echo "[update] loop core updated: ${CORE_VERSION_BEFORE} → $(cat "$LOOP_ROOT/VERSION" 2>/dev/null || echo unknown)"
fi

if ! $MONITOR_UP_TO_DATE && [ -d "${LOOP_MONITOR_ROOT}/.git" ]; then
    MON_FROM_SHA="$(cd "$LOOP_MONITOR_ROOT" && git rev-parse HEAD)"
    echo "[update] applying loop-monitor …"
    echo "[update] loop-monitor: ${MONITOR_VERSION_BEFORE} → applying …"
    (cd "$LOOP_MONITOR_ROOT" && git merge --ff-only origin/main)
    MON_TO_SHA="$(cd "$LOOP_MONITOR_ROOT" && git rev-parse HEAD)"
    _record_update "loop-monitor" "$MON_FROM_SHA" "$MON_TO_SHA"
    echo "[update] loop-monitor updated: ${MONITOR_VERSION_BEFORE} → $(cat "${LOOP_MONITOR_ROOT}/VERSION" 2>/dev/null || echo unknown)"
    _restart_monitor
fi

echo "[update] done."
