#!/usr/bin/env bash
# auto-release-pr.sh — Maintain one open "chore: release vX.Y.Z" PR per project.
#
# Computes the next version from merged PR semver labels since the last git tag,
# promotes CHANGELOG.md [Unreleased] → [X.Y.Z], bumps VERSION, and opens (or
# updates) a PR titled "chore: release vX.Y.Z" with label "release-pr".
#
# Usage:
#   scripts/auto-release-pr.sh --slug <slug> [--dry-run]
#   LOOP_SLUG=<slug> scripts/auto-release-pr.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/env.sh
source "$LOOP_ROOT/lib/env.sh"
# shellcheck source=../lib/config.sh
source "$LOOP_ROOT/lib/config.sh"
# shellcheck source=../lib/backends/backend.sh
source "$LOOP_ROOT/lib/backends/backend.sh"

LOG_FILE="${LOOP_LOG_DIR}/loop-auto-release-pr.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-release-pr] $*" | tee -a "$LOG_FILE"; }

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

SLUG="${LOOP_SLUG:-}"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)
            SLUG="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            log "ERROR: unknown argument '$1'"
            exit 2
            ;;
    esac
done

[ -n "$SLUG" ] || { log "ERROR: --slug <slug> is required (or set LOOP_SLUG)"; exit 2; }

loop_load_project "$SLUG" || { log "ERROR: unknown slug '$SLUG'"; exit 2; }
loop_load_backend

log "slug=$SLUG repo=$REPO root=$ROOT dry_run=$DRY_RUN"

# ─────────────────────────────────────────────────────────────────────────────
# Ensure release-pr label exists in the repo
# ─────────────────────────────────────────────────────────────────────────────

if ! $DRY_RUN; then
    gh label create "release-pr" \
        --repo "$REPO" \
        --color "#0075ca" \
        --description "Automated release PR" \
        2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# Read current version
# ─────────────────────────────────────────────────────────────────────────────

VERSION_FILE="$ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    log "ERROR: $VERSION_FILE not found"
    exit 2
fi

CURRENT_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if [ -z "$CURRENT_VERSION" ]; then
    log "ERROR: VERSION file is empty"
    exit 2
fi

log "current version: $CURRENT_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
# Check CHANGELOG.md [Unreleased] section — bail if empty
# ─────────────────────────────────────────────────────────────────────────────

CHANGELOG_FILE="$ROOT/CHANGELOG.md"
if [ ! -f "$CHANGELOG_FILE" ]; then
    log "ERROR: $CHANGELOG_FILE not found"
    exit 2
fi

UNRELEASED_EMPTY=$(python3 <<PY
import re, sys

with open("$CHANGELOG_FILE") as f:
    content = f.read()

m = re.search(r'## \[Unreleased\][^\n]*\n', content)
if not m:
    print("no-section")
    sys.exit(0)

block_start = m.end()
next_sec = re.search(r'\n## ', content[block_start:])
block_end = (block_start + next_sec.start()) if next_sec else len(content)
block = content[block_start:block_end].strip()
print("empty" if not block else "has-content")
PY
)

if [ "$UNRELEASED_EMPTY" = "no-section" ]; then
    log "ERROR: CHANGELOG.md has no [Unreleased] section"
    exit 2
fi

if [ "$UNRELEASED_EMPTY" = "empty" ]; then
    log "nothing to release: [Unreleased] section is empty"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Determine next version from semver labels on merged PRs since last tag
# ─────────────────────────────────────────────────────────────────────────────

# Find the last tag date (or use epoch if none exist)
LAST_TAG_DATE=$(git -C "$ROOT" log --tags --simplify-by-decoration \
    --pretty="format:%aI" --max-count=1 2>/dev/null || true)

if [ -z "$LAST_TAG_DATE" ]; then
    log "no previous tags found — treating all merged PRs as unreleased"
    SINCE_ARG=""
else
    log "last tag date: $LAST_TAG_DATE"
    SINCE_ARG="--search=merged:>${LAST_TAG_DATE}"
fi

# Pull merged PR labels since last tag
if [ -n "$SINCE_ARG" ]; then
    # shellcheck disable=SC2086
    _MERGED_PRS_JSON=$(gh pr list --repo "$REPO" --state merged --limit 200 \
        --json labels,mergedAt \
        $SINCE_ARG \
        2>/dev/null || echo "[]")
else
    _MERGED_PRS_JSON=$(gh pr list --repo "$REPO" --state merged --limit 200 \
        --json labels,mergedAt \
        2>/dev/null || echo "[]")
fi

SEMVER_BUMP=$(python3 <<PY
import json

prs = json.loads("""${_MERGED_PRS_JSON}""")
bump = "patch"
for pr in prs:
    for lbl in pr.get("labels", []):
        name = lbl.get("name", "")
        if name == "semver:major":
            bump = "major"
            break
        if name == "semver:minor" and bump != "major":
            bump = "minor"
print(bump)
PY
)

log "semver bump: $SEMVER_BUMP"

# Compute next version
NEXT_VERSION=$(python3 <<PY
parts = "$CURRENT_VERSION".lstrip("v").split(".")
major, minor, patch = int(parts[0]), int(parts[1] if len(parts)>1 else 0), int(parts[2] if len(parts)>2 else 0)
bump = "$SEMVER_BUMP"
if bump == "major":
    major += 1; minor = 0; patch = 0
elif bump == "minor":
    minor += 1; patch = 0
else:
    patch += 1
print(f"{major}.{minor}.{patch}")
PY
)

log "next version: $NEXT_VERSION"
RELEASE_BRANCH="release/v${NEXT_VERSION}"
PR_TITLE="chore: release v${NEXT_VERSION}"
TODAY=$(date '+%Y-%m-%d')

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency: check if a release PR for this version already exists
# ─────────────────────────────────────────────────────────────────────────────

EXISTING_PR=$(gh pr list --repo "$REPO" --state open \
    --json number,title \
    2>/dev/null \
    | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for pr in prs:
    if pr['title'] == '$PR_TITLE':
        print(pr['number'])
        break
" 2>/dev/null || true)

if [ -n "$EXISTING_PR" ]; then
    log "release PR for v${NEXT_VERSION} already exists (#${EXISTING_PR}) — nothing to do"
    exit 0
fi

if $DRY_RUN; then
    log "[DRY-RUN] would create branch: $RELEASE_BRANCH"
    log "[DRY-RUN] would bump VERSION: $CURRENT_VERSION → $NEXT_VERSION"
    log "[DRY-RUN] would promote CHANGELOG [Unreleased] → [$NEXT_VERSION] - $TODAY"
    log "[DRY-RUN] would open PR: '$PR_TITLE' with label 'release-pr'"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Prepare the release branch
# ─────────────────────────────────────────────────────────────────────────────

# Pull latest default branch
git -C "$ROOT" fetch origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE" || true
git -C "$ROOT" fetch origin --tags 2>&1 | tee -a "$LOG_FILE" || true

# Delete stale remote release branch if present
if git -C "$ROOT" ls-remote --exit-code --heads origin "$RELEASE_BRANCH" >/dev/null 2>&1; then
    log "deleting stale remote branch: $RELEASE_BRANCH"
    git -C "$ROOT" push origin --delete "$RELEASE_BRANCH" 2>&1 | tee -a "$LOG_FILE" || true
fi

# Create branch from default branch
git -C "$ROOT" checkout -B "$RELEASE_BRANCH" "origin/${DEFAULT_BRANCH}" 2>&1 | tee -a "$LOG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Commit 1: bump VERSION
# ─────────────────────────────────────────────────────────────────────────────

printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
git -C "$ROOT" add "$VERSION_FILE"
git -C "$ROOT" commit -m "chore(release): bump VERSION to ${NEXT_VERSION}" 2>&1 | tee -a "$LOG_FILE"
log "committed VERSION bump: $CURRENT_VERSION → $NEXT_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
# Commit 2: promote CHANGELOG
# ─────────────────────────────────────────────────────────────────────────────

CHANGELOG_PATH="$CHANGELOG_FILE" NEXT_VER="$NEXT_VERSION" RELEASE_DATE="$TODAY" \
python3 <<'PY'
import os, re

changelog_path = os.environ['CHANGELOG_PATH']
next_ver       = os.environ['NEXT_VER']
release_date   = os.environ['RELEASE_DATE']

with open(changelog_path) as f:
    content = f.read()

# Build the new released header
released_header = f"## [{next_ver}] - {release_date}"

# Replace `## [Unreleased]` with new empty section + released block
# Pattern: "## [Unreleased]" followed by optional trailing text on same line
content = re.sub(
    r'## \[Unreleased\][^\n]*',
    f"## [Unreleased]\n\n{released_header}",
    content,
    count=1,
)

with open(changelog_path, 'w') as f:
    f.write(content)

print(f"CHANGELOG: promoted [Unreleased] -> [{next_ver}] - {release_date}")
PY

git -C "$ROOT" add "$CHANGELOG_FILE"
git -C "$ROOT" commit -m "chore(release): promote CHANGELOG for v${NEXT_VERSION}" 2>&1 | tee -a "$LOG_FILE"
log "committed CHANGELOG promotion for v${NEXT_VERSION}"

# ─────────────────────────────────────────────────────────────────────────────
# Push release branch
# ─────────────────────────────────────────────────────────────────────────────

git -C "$ROOT" push origin "$RELEASE_BRANCH" 2>&1 | tee -a "$LOG_FILE"
log "pushed branch: $RELEASE_BRANCH"

# ─────────────────────────────────────────────────────────────────────────────
# Extract CHANGELOG section for PR body
# ─────────────────────────────────────────────────────────────────────────────

PR_BODY=$(CHANGELOG_PATH="$CHANGELOG_FILE" NEXT_VER="$NEXT_VERSION" python3 <<'PY'
import os, re

changelog_path = os.environ['CHANGELOG_PATH']
next_ver       = os.environ['NEXT_VER']

with open(changelog_path) as f:
    content = f.read()

pattern = re.escape(f"## [{next_ver}]")
m = re.search(pattern, content)
if not m:
    print(f"## [{next_ver}] release")
else:
    block_start = m.start()
    next_sec = re.search(r'\n## ', content[m.end():])
    block_end = (m.end() + next_sec.start()) if next_sec else len(content)
    print(content[block_start:block_end].strip())
PY
)

# ─────────────────────────────────────────────────────────────────────────────
# Open the release PR
# ─────────────────────────────────────────────────────────────────────────────

TMPBODY=$(mktemp)
printf '%s\n' "$PR_BODY" > "$TMPBODY"

NEW_PR_NUM=$(gh pr create \
    --repo "$REPO" \
    --title "$PR_TITLE" \
    --body-file "$TMPBODY" \
    --label "release-pr" \
    --base "$DEFAULT_BRANCH" \
    --head "$RELEASE_BRANCH" \
    2>&1 | tee -a "$LOG_FILE" \
    | python3 -c "import re,sys; m=re.search(r'/pull/(\d+)', sys.stdin.read()); print(m.group(1) if m else '')" \
    || true)

rm -f "$TMPBODY"

if [ -n "$NEW_PR_NUM" ]; then
    log "opened release PR #${NEW_PR_NUM}: '$PR_TITLE'"
else
    log "WARN: PR may have been created but number could not be extracted — check GitHub"
fi

# Restore to default branch (leave worktree clean)
git -C "$ROOT" checkout "$DEFAULT_BRANCH" 2>/dev/null || true

log "auto-release-pr done for v${NEXT_VERSION}"
