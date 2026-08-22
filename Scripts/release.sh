#!/bin/bash
# Cuts a release: verifies the tree, tags it, and pushes the tag.
#
# The tag is the only place a version is written down, so this is the whole versioning process —
# the workflow reads `GITHUB_REF_NAME` and stamps it into the bundle. Nothing in the repo needs
# editing, and nothing can drift out of sync with the tag.
#
#   Scripts/release.sh 0.2.0        cut v0.2.0
#   Scripts/release.sh patch        bump the last released version's patch component
#   Scripts/release.sh minor|major  likewise
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ $# -ne 1 ]; then
    echo "usage: Scripts/release.sh <version|patch|minor|major>" >&2
    exit 1
fi

current() {
    git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0"
}

bump() {
    local part="$1" version major minor patch
    version="$(current)"
    IFS=. read -r major minor patch <<< "$version"
    major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
    case "$part" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
    esac
}

case "$1" in
    major|minor|patch) VERSION="$(bump "$1")" ;;
    *) VERSION="${1#v}" ;;
esac

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "error: '$VERSION' is not a semantic version" >&2
    exit 1
fi

TAG="v$VERSION"

# A tag that points at uncommitted work describes a build nobody else can reproduce.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty — commit or stash first" >&2
    git status --short >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: $TAG already exists" >&2
    exit 1
fi

# The release workflow runs these too, but finding out here costs seconds instead of a failed
# release and a tag that has to be deleted from two places.
echo "Running tests…"
swift test > /dev/null

echo "Building…"
MACHLINE_VERSION="$VERSION" ./Scripts/build-app.sh release > /dev/null

echo
echo "Ready to tag $TAG at $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)."
printf 'Tag and push? [y/N] '
read -r reply
case "$reply" in
    [yY]*) ;;
    *) echo "Nothing tagged."; exit 0 ;;
esac

git tag -a "$TAG" -m "Machline $VERSION"
git push origin "$TAG"

echo
echo "Pushed $TAG. The release workflow builds the DMG and publishes it:"
echo "  https://github.com/Ehsan200/Machline/actions"
