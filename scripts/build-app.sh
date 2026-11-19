#!/bin/bash
# Builds "Toolbox Pro Max.app" and a .dmg into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
APP="build/Toolbox Pro Max.app"
DMG="build/Toolbox-Pro-Max-$VERSION.dmg"

echo "▸ Compiling (release)"
swift build -c release --arch arm64

echo "▸ Icon"
if [ ! -f Resources/AppIcon.icns ] || [ scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "▸ Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN=$(swift build -c release --arch arm64 --show-bin-path)
cp "$BIN/ToolboxProMax" "$APP/Contents/MacOS/ToolboxProMax"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "▸ Disk image"
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "Toolbox Pro Max" -srcfolder build/dmg -ov -format UDZO "$DMG"
rm -rf build/dmg

echo "✓ $APP"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
