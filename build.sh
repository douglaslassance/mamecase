#!/usr/bin/env bash
# Produces a signed, notarized DMG at dist/mamecase-<version>-aarch64-apple-darwin.dmg
# plus a .sha256 sidecar. Wraps ./bundle.sh and adds the release pipeline.
#
# Env vars (typically loaded from .env at the repo root):
#   APPLE_SIGNING_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARIZATION_KEY_ID     App Store Connect key ID
#   NOTARIZATION_ISSUER_ID  App Store Connect issuer ID
#   NOTARIZATION_KEY        base64-encoded .p8 contents
#
# Without APPLE_SIGNING_IDENTITY the app is ad-hoc signed (DMG still built, no
# notarization). Without notarization creds the notarize step is skipped.

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
build.sh — sign, package, and notarize a Mamecase release.

Usage: ./build.sh [version]
  version  optional; defaults to latest git tag or 0.0.0
EOF
    exit 0
fi

set -euo pipefail

cd "$(dirname "$0")"

[ -f .env ] && source .env

APP_NAME="Mamecase"
REPO_NAME="mamecase"
TARGET="aarch64-apple-darwin"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
DIST_DIR="dist"
DMG_NAME="${REPO_NAME}-${VERSION}-${TARGET}.dmg"

echo "▸ building ${APP_NAME} v${VERSION}"
mkdir -p "$DIST_DIR"

# 1. Build the unsigned .app bundle.
./bundle.sh "$VERSION"

# 2. Sign the app bundle (Developer ID + hardened runtime if available, else ad-hoc).
APP_DIR="${APP_NAME}.app"
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    echo "▸ codesign (Developer ID)"
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" \
        --entitlements "${APP_NAME}.entitlements" \
        --options runtime --timestamp \
        "$APP_DIR"
else
    echo "▸ codesign (ad-hoc; set APPLE_SIGNING_IDENTITY to enable notarization)"
    codesign --force --sign - \
        --entitlements "${APP_NAME}.entitlements" \
        "$APP_DIR"
fi

# 3. Build the DMG (mount under /tmp to dodge /Volumes TCC prompts).
echo "▸ building DMG"
rm -f "${DIST_DIR}/${DMG_NAME}"
DMG_MOUNT="/tmp/${REPO_NAME}-dmg-$$"
DMG_TEMP="/tmp/${REPO_NAME}-temp-$$.dmg"
mkdir -p "$DMG_MOUNT"
hdiutil create -size 200m -fs HFS+ -volname "$APP_NAME" "$DMG_TEMP" -quiet
hdiutil attach "$DMG_TEMP" -nobrowse -noverify -noautoopen -mountpoint "$DMG_MOUNT" -quiet
ditto "$APP_DIR" "${DMG_MOUNT}/${APP_DIR}"
ln -sf /Applications "${DMG_MOUNT}/Applications"
hdiutil detach "$DMG_MOUNT" -quiet
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "${DIST_DIR}/${DMG_NAME}" -quiet
rm -f "$DMG_TEMP"
rmdir "$DMG_MOUNT"

# 4. Sign the DMG itself when we have Developer ID.
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    echo "▸ codesign DMG"
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" "${DIST_DIR}/${DMG_NAME}"
fi

# 5. Notarize + staple.
if [ -n "${NOTARIZATION_KEY_ID:-}" ] && [ -n "${NOTARIZATION_ISSUER_ID:-}" ] && [ -n "${NOTARIZATION_KEY:-}" ]; then
    echo "▸ notarize"
    KEY_FILE=$(mktemp /tmp/notarize_XXXXXX)
    trap 'rm -f "$KEY_FILE"' EXIT
    echo "$NOTARIZATION_KEY" | base64 --decode > "$KEY_FILE"

    SUBMIT_OUTPUT=$(xcrun notarytool submit "${DIST_DIR}/${DMG_NAME}" \
        --key "$KEY_FILE" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$SUBMIT_OUTPUT"
    SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep -E '^\s*id:' | head -1 | awk '{print $2}')
    if [ -z "$SUBMISSION_ID" ]; then
        echo "❌ no submission id returned"
        exit 1
    fi

    WAIT_OUTPUT=$(xcrun notarytool wait "$SUBMISSION_ID" \
        --key "$KEY_FILE" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$WAIT_OUTPUT"
    STATUS=$(echo "$WAIT_OUTPUT" | grep -E 'status:' | tail -1 | awk '{print $2}')
    if [ "$STATUS" != "Accepted" ]; then
        echo "❌ notarization status: $STATUS"
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$KEY_FILE" \
            --key-id "$NOTARIZATION_KEY_ID" \
            --issuer "$NOTARIZATION_ISSUER_ID" 2>&1 || true
        exit 1
    fi

    echo "▸ staple"
    xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"
else
    echo "▸ notarization skipped (set NOTARIZATION_KEY_ID/ISSUER_ID/KEY to enable)"
fi

# 6. Checksum (after stapling — stapling rewrites the DMG).
echo "▸ checksum"
shasum -a 256 "${DIST_DIR}/${DMG_NAME}" > "${DIST_DIR}/${DMG_NAME}.sha256"
cat "${DIST_DIR}/${DMG_NAME}.sha256"

echo "✓ ${DIST_DIR}/${DMG_NAME}"
