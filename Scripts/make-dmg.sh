#!/bin/bash
# Packages Machline.app into a disk image.
#
# `hdiutil` rather than a packaging dependency: a DMG with the app and an Applications shortcut is
# a directory and one command, and every extra tool here is one more thing to keep working.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Machline.app"
VERSION="${MACHLINE_VERSION:-dev}"
DMG="$ROOT/.build/Machline-$VERSION.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP does not exist — run Scripts/build-app.sh first" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
# The conventional drag-to-install target.
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Machline $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" > /dev/null

echo "Built $DMG"
