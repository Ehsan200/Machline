#!/bin/bash
# Assembles Machline.app from the SPM build products.
#
# SwiftPM cannot emit an application bundle, and the app needs one: a bare executable gets no
# Info.plist, so macOS treats it as a background tool with no Dock presence and no menu bar. This
# script builds the executable, lays out the bundle around it, and copies in the helper binaries
# the app spawns at runtime.
set -euo pipefail

CONFIGURATION="${1:-debug}"
# The git tag is the source of truth in CI; a local build says so rather than claiming a version.
VERSION="${MACHLINE_VERSION:-0.0.0-dev}"
BUILD="${MACHLINE_BUILD:-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/.build/Machline.app"

# `set -u` treats an empty array expansion as unbound on bash 3.2, which is what macOS ships.
BUILD_FLAGS=""
if [ "$CONFIGURATION" = "release" ]; then
    BUILD_FLAGS="--configuration release"
fi

cd "$ROOT"
for PRODUCT in Machline harness-approve harness-mcp-proxy; do
    # shellcheck disable=SC2086
    swift build $BUILD_FLAGS --product "$PRODUCT"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Machline" "$APP/Contents/MacOS/Machline"
# The app resolves these from its own bundle at runtime; a missing approval helper is a hard
# failure, because a session that cannot be gated must not start.
cp "$BUILD_DIR/harness-approve" "$APP/Contents/MacOS/harness-approve"
cp "$BUILD_DIR/harness-mcp-proxy" "$APP/Contents/MacOS/harness-mcp-proxy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Machline</string>
    <key>CFBundleDisplayName</key><string>Machline</string>
    <key>CFBundleIdentifier</key><string>dev.machline.app</string>
    <key>CFBundleExecutable</key><string>Machline</string>
    <key>CFBundleIconFile</key><string>Machline</string>
    <!-- Where the update check looks. Empty disables it; a fork points at its own releases. -->
    <key>MachlineUpdateRepository</key><string>${MACHLINE_REPOSITORY:-Ehsan200/Machline}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# The icon is generated from source rather than checked in as a binary, so it stays editable.
"$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/Machline.icns"

plutil -lint "$APP/Contents/Info.plist" > /dev/null
# Ad-hoc signature: enough for local runs, and keeps the bundle from being killed on launch.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed; the app may not launch"

echo "Built $APP"
