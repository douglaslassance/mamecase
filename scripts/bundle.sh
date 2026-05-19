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

# SPM emits resource catalogs (asset symbolsets, etc.) into a sibling
# `<Module>_<Module>.bundle` next to the executable. We have to copy
# that into the app's Resources or Bundle.module / our custom
# appResources lookup can't find it at runtime.
RES_BUNDLE="${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$BUILD_DIR/$RES_BUNDLE" ]; then
    echo "▸ copying resource bundle"
    cp -R "$BUILD_DIR/$RES_BUNDLE" "$RESOURCES/$RES_BUNDLE"

    # swift build doesn't run actool, so the asset catalog stays as a
    # raw `Assets.xcassets` directory which SwiftUI's `Image(name:bundle:)`
    # can't read. Compile it manually into `Assets.car` next to the
    # source catalog, then drop the source to keep the bundle clean.
    if [ -d "$RESOURCES/$RES_BUNDLE/Assets.xcassets" ]; then
        echo "▸ compiling asset catalog"
        xcrun actool \
            --compile "$RESOURCES/$RES_BUNDLE" \
            --platform macosx \
            --minimum-deployment-target 14.0 \
            --target-device mac \
            --output-format human-readable-text \
            "$RESOURCES/$RES_BUNDLE/Assets.xcassets" > /dev/null
        rm -rf "$RESOURCES/$RES_BUNDLE/Assets.xcassets"
    fi
fi

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
