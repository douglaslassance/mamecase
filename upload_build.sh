#!/usr/bin/env bash
# Publishes dist/mamecase-<version>-aarch64-apple-darwin.dmg as a GitHub release
# (tag v<version>). Creates the release if missing, otherwise uploads the assets
# to it, overwriting any prior copies.
#
# Auth: uses gh's existing login. Set GITHUB_PERSONAL_ACCESS_TOKEN in .env to
# override (exported as GH_TOKEN for the gh CLI).

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
upload_build.sh — push the built DMG to GitHub Releases.

Usage: ./upload_build.sh [version]
  version  optional; defaults to latest git tag or 0.0.0

Pre-requisites:
  - ./build.sh has been run for the same version
  - gh CLI authenticated (or GITHUB_PERSONAL_ACCESS_TOKEN set)
EOF
    exit 0
fi

set -euo pipefail

cd "$(dirname "$0")"

[ -f .env ] && source .env

if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"
fi

REPO_NAME="mamecase"
TARGET="aarch64-apple-darwin"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"

if [ -z "$VERSION" ]; then
    echo "❌ version could not be determined (pass as arg or create a git tag)"
    exit 1
fi

DIST_DIR="dist"
DMG_FILE="${REPO_NAME}-${VERSION}-${TARGET}.dmg"
SHA_FILE="${DMG_FILE}.sha256"
TAG="v${VERSION}"

for f in "$DMG_FILE" "$SHA_FILE"; do
    if [ ! -f "${DIST_DIR}/${f}" ]; then
        echo "❌ ${DIST_DIR}/${f} not found — run ./build.sh ${VERSION} first"
        exit 1
    fi
done

# Check pre-release naming so we can flag the GitHub release accordingly.
PRERELEASE_FLAG=""
if echo "$VERSION" | grep -qiE '(alpha|beta|rc|pre|dev)'; then
    PRERELEASE_FLAG="--prerelease"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "▸ release ${TAG} exists, uploading assets (clobber)"
    gh release upload "$TAG" \
        "${DIST_DIR}/${DMG_FILE}" \
        "${DIST_DIR}/${SHA_FILE}" \
        --clobber
else
    echo "▸ creating release ${TAG}"
    gh release create "$TAG" \
        --title "$TAG" \
        --notes "Release ${TAG}" \
        $PRERELEASE_FLAG \
        "${DIST_DIR}/${DMG_FILE}" \
        "${DIST_DIR}/${SHA_FILE}"
fi

echo "✓ https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/${TAG}"
