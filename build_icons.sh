#!/usr/bin/env bash
# Regenerate the app icons from AppIcon.icon, the Icon Composer document that
# is the single source of truth for the Mamecase mark.
#
#   ./build_icons.sh
#
# Outputs (build/ is gitignored, so this runs on every release build via
# [build] icon_command in catapult.toml):
#   build/Assets.car        compiled adaptive icon. macOS 26 picks the light,
#                           dark or tinted rendition from it, keyed by
#                           CFBundleIconName in the generated Info.plist.
#   build/AppIcon.icns      legacy flat icon, used by older macOS.
#   AppIcon.icon/Assets/    the rasterised picto the document paints
#                           (committed, it is part of the document).
#
# Requires Icon Composer (for ictool) and Xcode (for actool).

set -euo pipefail

cd "$(dirname "$0")"

ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
DOC="AppIcon.icon"
OUT="build"

if [[ ! -x "$ICTOOL" ]]; then
  echo "Icon Composer not found at $ICTOOL" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# 1. Rasterise the picto as an alpha mask for the document's layer.
swift make_glyph.swift

# 2. Flatten the light rendition and build the legacy .icns from it.
"$ICTOOL" "$DOC" \
  --export-image \
  --output-file "$WORK/source.png" \
  --platform macOS \
  --rendition Light \
  --width 1024 --height 1024 --scale 1

rm -rf "$OUT/icon.iconset"
mkdir -p "$OUT/icon.iconset"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$WORK/source.png" --out "$OUT/icon.iconset/icon_$2.png" >/dev/null
done
iconutil -c icns "$OUT/icon.iconset" -o "$OUT/AppIcon.icns"

# 3. Adaptive icon: document -> asset catalog -> patch the dark appearance ->
#    Assets.car. See patch_icon_ir.py for why the patch is needed.
mkdir -p "$WORK/ir"
"$ICTOOL" "$DOC" \
  --export-intermediate-representation \
  --platform macOS \
  --output-directory "$WORK/ir" >/dev/null
python3 patch_icon_ir.py "$WORK/ir"
mkdir -p "$WORK/car"
xcrun actool "$WORK/ir/AppIcon.icon.xcassets" \
  --compile "$WORK/car" \
  --app-icon AppIcon \
  --include-all-app-icons \
  --minimum-deployment-target 26.0 \
  --platform macosx \
  --output-partial-info-plist "$WORK/partial.plist" \
  --errors --warnings >/dev/null
cp "$WORK/car/Assets.car" "$OUT/Assets.car"

echo "Icons regenerated from $DOC"
