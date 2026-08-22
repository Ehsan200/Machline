#!/bin/bash
# Renders Machline.icns from Scripts/make-icon.swift.
#
# The icon is drawn in code rather than checked in as a binary, so a change to it shows up as a
# reviewable diff. Regenerated only when the source is newer than the output — compiling the
# renderer costs a couple of seconds and the icon rarely changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Scripts/make-icon.swift"
OUTPUT="${1:-$ROOT/.build/Machline.icns}"
CACHE="$ROOT/.build/icon"

if [ -f "$OUTPUT" ] && [ "$OUTPUT" -nt "$SOURCE" ]; then
    exit 0
fi

# A cached copy avoids re-rendering for every bundle assembly.
if [ -f "$CACHE/Machline.icns" ] && [ "$CACHE/Machline.icns" -nt "$SOURCE" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$CACHE/Machline.icns" "$OUTPUT"
    exit 0
fi

ICONSET="$CACHE/Machline.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift "$SOURCE" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$CACHE/Machline.icns"

mkdir -p "$(dirname "$OUTPUT")"
cp "$CACHE/Machline.icns" "$OUTPUT"
