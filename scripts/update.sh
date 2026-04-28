#!/usr/bin/env bash
# scripts/update.sh — single-command updater for loop core + loop-monitor.
# Usage: loop update [--check] [--core-only] [--monitor-only] [--dry-run] [--to <tag>] [--rollback] [--yes]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-update.log"
UPDATE_HISTORY="${HOME}/.loop/update-history.log"

# ── Defaults ──────────────────────────────────────────────────────────────────
OPT_CHECK=false
OPT_CORE_ONLY=false
OPT_MONITOR_ONLY=false
OPT_DRY_RUN=false
OPT_TO=""
OPT_ROLLBACK=false
OPT_YES=false

# Default core dir to the loop repo itself; monitor dir must be configured via loop.env
LOOP_CORE_DIR="${LOOP_CORE_DIR:-${LOOP_ROOT}}"
LOOP_MONITOR_DIR="${LOOP_MONITOR_DIR:-}"
MONITOR_LABEL="com.loop.loop-monitor"
MONITOR_HEALTH_URL="${LOOP_MONITOR_HEALTH_URL:-http://localhost:7842/api/health}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [update] $*" | tee -a "$LOG_FILE"; }
info() { echo "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)        OPT_CHECK=true ;;
        --core-only)    OPT_CORE_ONLY=true ;;
        --monitor-only) OPT_MONITOR_ONLY=true ;;
        --dry-run)      OPT_DRY_RUN=true ;;
        --to)           shift; OPT_TO="${1:-}"; [[ -n "$OPT_TO" ]] || die "--to requires a tag argument" ;;
        --rollback)     OPT_ROLLBACK=true ;;
        --yes)          OPT_YES=true ;;
        -*)             die "Unknown flag: $1" ;;
        *)              die "Unexpected argument: $1" ;;
    esac
    shift
done

mkdir -p "$(dirname "$UPDATE_HISTORY")"

# ── Helpers ───────────────────────────────────────────────────────────────────
run_or_dry() {
    # run_or_dry <description> <cmd> [args...]
    local desc="$1"; shift
    if $OPT_DRY_RUN; then
        info "  [dry-run] $desc: $*"
    else
        "$@"
    fi
}

repo_version() {
    local dir="$1"
    local vfile="$dir/VERSION"
    if [[ -f "$vfile" ]]; then
        tr -d '[:space:]' < "$vfile"
    else
        git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown"
    fi
}

changelog_delta() {
    # Print CHANGELOG entries between $1 (old sha/tag) and $2 (new sha/tag) in $3 (dir).
    local old_ref="$1" new_ref="$2" dir="$3"
    git -C "$dir" log --oneline "${old_ref}..${new_ref}" 2>/dev/null || true
}

has_breaking() {
    # Return 0 if any commit message in range contains "BREAKING:"
    local old_ref="$1" new_ref="$2" dir="$3"
    git -C "$dir" log --oneline "${old_ref}..${new_ref}" 2>/dev/null \
        | grep -qi "BREAKING:" && return 0
    # Also scan CHANGELOG if present
    local cl="$dir/CHANGELOG.md"
    if [[ -f "$cl" ]]; then
        git -C "$dir" diff "${old_ref}..${new_ref}" -- CHANGELOG.md 2>/dev/null \
            | grep -qi "^+.*BREAKING:" && return 0
    fi
    return 1
}

record_history() {
    local label="$1" sha="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $label $sha" >> "$UPDATE_HISTORY"
}

# ── Rollback ──────────────────────────────────────────────────────────────────
if $OPT_ROLLBACK; then
    [[ -f "$UPDATE_HISTORY" ]] || die "No update history found at $UPDATE_HISTORY"
    log "Rolling back from update history …"
    _core_sha=$(grep " core " "$UPDATE_HISTORY" 2>/dev/null | tail -1 | awk '{print $3}')
    _monitor_sha=$(grep " monitor " "$UPDATE_HISTORY" 2>/dev/null | tail -1 | awk '{print $3}')

    for label in core monitor; do
        if [[ "$label" == "core" ]]; then
            sha="$_core_sha"
            local_dir="$LOOP_CORE_DIR"
        else
            sha="$_monitor_sha"
            local_dir="$LOOP_MONITOR_DIR"
        fi
        if [[ -z "$sha" ]]; then
            info "  No previous SHA recorded for $label — skipping"
            continue
        fi
        if [[ ! -d "$local_dir" ]]; then
            info "  $label dir not found at $local_dir — skipping"
            continue
        fi
        info "Rolling back $label to $sha …"
        run_or_dry "checkout $label to $sha" git -C "$local_dir" checkout "$sha"
    done
    info "Rollback complete. Restart services manually if needed."
    exit 0
fi

# ── Determine which repos to update ──────────────────────────────────────────
DO_CORE=true
DO_MONITOR=true
$OPT_CORE_ONLY    && DO_MONITOR=false
$OPT_MONITOR_ONLY && DO_CORE=false

# ── Validate dirs ─────────────────────────────────────────────────────────────
if $DO_CORE && [[ ! -d "$LOOP_CORE_DIR/.git" ]]; then
    die "loop core dir not found or not a git repo: $LOOP_CORE_DIR (set LOOP_CORE_DIR in loop.env)"
fi
if $DO_MONITOR && [[ ! -d "$LOOP_MONITOR_DIR/.git" ]]; then
    log "loop-monitor dir not found at $LOOP_MONITOR_DIR — skipping monitor steps"
    DO_MONITOR=false
fi

# ── fetch + plan ──────────────────────────────────────────────────────────────
info "=== Loop Update $(date '+%Y-%m-%d %H:%M:%S') ==="

fetch_repo() {
    local label="$1" dir="$2"
    info ""
    info "── $label ($dir)"
    run_or_dry "git fetch $label" git -C "$dir" fetch --tags --quiet
}

$DO_CORE    && fetch_repo "core" "$LOOP_CORE_DIR"
$DO_MONITOR && fetch_repo "monitor" "$LOOP_MONITOR_DIR"

plan_repo() {
    local label="$1" dir="$2"
    local cur_sha target_ref delta

    cur_sha=$(git -C "$dir" rev-parse HEAD)
    if [[ -n "$OPT_TO" ]]; then
        target_ref="$OPT_TO"
    else
        target_ref="origin/main"
    fi

    target_sha=$(git -C "$dir" rev-parse "${target_ref}" 2>/dev/null) \
        || { info "  $label: target ref $target_ref not found — skipping"; return 1; }

    info ""
    info "── $label changelog ($cur_sha → $target_sha)"
    delta=$(changelog_delta "$cur_sha" "$target_sha" "$dir")
    if [[ -z "$delta" ]]; then
        info "  (already up to date)"
    else
        echo "$delta" | sed 's/^/  /'
    fi

    # breaking check
    if has_breaking "$cur_sha" "$target_sha" "$dir"; then
        info ""
        info "  ⚠  BREAKING CHANGE detected in $label. Pass --yes to proceed."
        echo "BREAKING_${label^^}=true"
    fi

    echo "CUR_SHA_${label^^}=$cur_sha"
    echo "TARGET_SHA_${label^^}=$target_sha"
    echo "TARGET_REF_${label^^}=$target_ref"
    return 0
}

BREAKING_CORE=false
BREAKING_MONITOR=false
CUR_SHA_CORE=""
CUR_SHA_MONITOR=""
TARGET_SHA_MONITOR=""
TARGET_REF_CORE=""
TARGET_REF_MONITOR=""

# Capture plan output for variable extraction
if $DO_CORE; then
    _plan=$(plan_repo "core" "$LOOP_CORE_DIR" 2>&1) || true
    echo "$_plan" | grep -v '^[A-Z_]*=' || true
    # eval safe vars: only uppercase alphanum + underscore, starts with known prefix
    while IFS='=' read -r k v; do
        case "$k" in
            BREAKING_CORE|CUR_SHA_CORE|TARGET_REF_CORE)
                printf -v "$k" '%s' "$v" ;;
        esac
    done < <(echo "$_plan" | grep '^[A-Z_]*=')
fi

if $DO_MONITOR; then
    _plan=$(plan_repo "monitor" "$LOOP_MONITOR_DIR" 2>&1) || true
    echo "$_plan" | grep -v '^[A-Z_]*=' || true
    while IFS='=' read -r k v; do
        case "$k" in
            BREAKING_MONITOR|CUR_SHA_MONITOR|TARGET_SHA_MONITOR|TARGET_REF_MONITOR)
                printf -v "$k" '%s' "$v" ;;
        esac
    done < <(echo "$_plan" | grep '^[A-Z_]*=')
fi

# ── Check mode exits here ─────────────────────────────────────────────────────
if $OPT_CHECK; then
    info ""
    info "-- check mode: no changes applied"
    exit 0
fi

# ── Breaking-change gate ───────────────────────────────────────────────────────
if { $BREAKING_CORE || $BREAKING_MONITOR; } && ! $OPT_YES; then
    die "Aborting due to breaking changes. Re-run with --yes to proceed."
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
apply_repo() {
    local label="$1" dir="$2" cur_sha="$3" target_ref="$4"
    local ver_before ver_after

    ver_before=$(repo_version "$dir")
    record_history "$label" "$cur_sha"

    if [[ -n "$OPT_TO" ]]; then
        run_or_dry "checkout $label to $OPT_TO" git -C "$dir" checkout "$OPT_TO"
    else
        run_or_dry "pull $label" git -C "$dir" pull --ff-only --quiet
    fi

    ver_after=$(repo_version "$dir")
    info "  $label: $ver_before → $ver_after"
}

info ""
info "=== Applying updates ==="

$DO_CORE    && apply_repo "core"    "$LOOP_CORE_DIR"    "$CUR_SHA_CORE"    "$TARGET_REF_CORE"
$DO_MONITOR && apply_repo "monitor" "$LOOP_MONITOR_DIR" "$CUR_SHA_MONITOR" "$TARGET_REF_MONITOR"

# ── Restart loop-monitor if it changed ────────────────────────────────────────
monitor_changed() {
    [[ -n "$CUR_SHA_MONITOR" && -n "$TARGET_SHA_MONITOR" && "$CUR_SHA_MONITOR" != "$TARGET_SHA_MONITOR" ]]
}

if $DO_MONITOR && monitor_changed; then
    info ""
    info "── Restarting loop-monitor …"
    if [[ "$(uname)" == "Darwin" ]]; then
        run_or_dry "launchctl kickstart loop-monitor" \
            launchctl kickstart -k "gui/$(id -u)/${MONITOR_LABEL}"
    else
        run_or_dry "systemctl restart loop-monitor" \
            systemctl --user restart loop-monitor 2>/dev/null \
            || run_or_dry "systemctl restart loop-monitor (system)" \
               systemctl restart loop-monitor
    fi

    # Wait for health endpoint
    if ! $OPT_DRY_RUN; then
        info "  Waiting for /api/health …"
        local_timeout=15
        deadline=$(( $(date +%s) + local_timeout ))
        new_ver=""
        while [[ $(date +%s) -lt $deadline ]]; do
            http_resp=$(curl -sf "$MONITOR_HEALTH_URL" 2>/dev/null || true)
            if [[ -n "$http_resp" ]]; then
                new_ver=$(echo "$http_resp" | python3 -c \
                    "import json,sys; d=json.load(sys.stdin); print(d.get('monitor_version',''))" 2>/dev/null || true)
                if [[ -n "$new_ver" ]]; then
                    info "  loop-monitor healthy — version: $new_ver"
                    break
                fi
            fi
            sleep 2
        done
        if [[ -z "$new_ver" ]]; then
            log "WARNING: loop-monitor did not respond within ${local_timeout}s"
            info "  Rollback instructions: loop update --rollback"
        fi
    fi
elif $DO_MONITOR && ! monitor_changed; then
    info ""
    info "── loop-monitor already up to date — skipping restart"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
info ""
info "=== Update complete ==="
if $OPT_DRY_RUN; then
    info "(dry-run — no changes were applied)"
fi
