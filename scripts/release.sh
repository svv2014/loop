#!/usr/bin/env bash
# release.sh — bump VERSION, prepend a CHANGELOG section, tag, push, draft release.
#
# Usage:
#   ./scripts/release.sh patch       # 0.1.0 → 0.1.1
#   ./scripts/release.sh minor       # 0.1.0 → 0.2.0
#   ./scripts/release.sh major       # 0.1.0 → 1.0.0
#   ./scripts/release.sh --dry-run patch
#
# Workflow:
#   1. Reads VERSION, computes the new one
#   2. Updates VERSION
#   3. Inserts a new section in CHANGELOG.md just below "## [Unreleased]"
#      using whatever lines are currently under [Unreleased]
#   4. git commit + git tag vX.Y.Z + git push (with tags)
#   5. gh release create vX.Y.Z --notes-from-tag
#
# Refuses to run if:
#   - working tree is dirty (uncommitted changes)
#   - current branch is not main
#   - [Unreleased] section is empty (nothing to release)

set -euo pipefail

LOOP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=false
BUMP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        patch|minor|major) BUMP="$1"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$BUMP" ] || { echo "usage: release.sh [--dry-run] patch|minor|major" >&2; exit 2; }

cd "$LOOP_ROOT"

# Sanity: working tree clean
if ! git diff-index --quiet HEAD --; then
    echo "[release] working tree is dirty — commit or stash first" >&2
    exit 1
fi

# Sanity: on main
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || { echo "[release] not on main (on $branch)" >&2; exit 1; }

# Read current version
[ -f VERSION ] || { echo "[release] VERSION file missing" >&2; exit 1; }
current=$(tr -d '[:space:]' < VERSION)
IFS='.' read -r major minor patch <<< "$current"
case "$BUMP" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
esac
new="${major}.${minor}.${patch}"

# Sanity: [Unreleased] has content
unreleased=$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md | sed '/^[[:space:]]*$/d')
if [ -z "$unreleased" ]; then
    echo "[release] [Unreleased] section is empty — nothing to release" >&2
    exit 1
fi

today=$(date '+%Y-%m-%d')

echo "[release] bump: $current → $new ($BUMP)"
echo "[release] date: $today"

if $DRY_RUN; then
    echo "[release] dry-run — would update VERSION + CHANGELOG, commit, tag v${new}, push, draft release"
    echo "[release] [Unreleased] content that would move to [${new}]:"
    awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md
    exit 0
fi

# Update VERSION
echo "$new" > VERSION

# Update CHANGELOG: insert a new dated section just below "## [Unreleased]"
python3 - "$new" "$today" <<'PY'
import sys, re
new_ver, today = sys.argv[1], sys.argv[2]
with open("CHANGELOG.md", "r") as f:
    content = f.read()
new_section = f"## [Unreleased]\n\n## [{new_ver}] - {today}"
content = re.sub(r"## \[Unreleased\]", new_section, content, count=1)
# Append link reference at bottom
link_line = f"[{new_ver}]: https://github.com/svv2014/loop/releases/tag/v{new_ver}\n"
if link_line not in content:
    content = content.rstrip() + "\n" + link_line
with open("CHANGELOG.md", "w") as f:
    f.write(content)
PY

git add VERSION CHANGELOG.md
git commit -m "release: v${new}"
git tag -a "v${new}" -m "Loop v${new}"
git push origin main
git push origin "v${new}"

if command -v gh >/dev/null 2>&1; then
    notes=$(awk -v ver="$new" '$0 ~ "^## \\[" ver "\\]"{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md)
    gh release create "v${new}" --title "Loop v${new}" --notes "$notes" || \
        echo "[release] gh release create failed — create manually if needed"
fi

echo "[release] done — v${new} published"
