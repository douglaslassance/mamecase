#!/usr/bin/env bash
# Produces Mamecase.app at the project root from a fresh release build.
# Run from anywhere; cd into the project root first.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Mamecase"
BUNDLE_ID="com.dlassance.mamecase"
VERSION="0.1.0"
BUILD="1"

BUILD_DIR=".build/release"
APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$RESOURCES/AppIcon.iconset"

echo "▸ swift build -c release"
swift build -c release

echo "▸ wiping previous bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

echo "▸ copying executable"
cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

echo "▸ rendering app icon"
rm -rf "$ICONSET"
swift scripts/render_icon.swift "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key><true/>
</dict>
</plist>
PLIST

echo "✓ built $APP_DIR"
