#!/usr/bin/env bash
# Bumps the mamecase cask in a Homebrew tap, runs local smoke tests, pushes a
# branch, and optionally opens a PR.
#
# Defaults to https://github.com/douglaslassance/homebrew-tap.git. Override
# with HOMEBREW_TAP_URL in .env (e.g. for Homebrew/homebrew-cask).
#
# Env vars (loaded from .env):
#   HOMEBREW_TAP_URL                default: https://github.com/douglaslassance/homebrew-tap.git
#   GITHUB_PERSONAL_ACCESS_TOKEN    used as GH_TOKEN for gh CLI
#   AUDIT_FLAGS                     optional extra flags for `brew audit`

PULL_REQUEST=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<EOF
submit_build.sh — bump the mamecase Homebrew cask.

Usage: ./submit_build.sh [--pull-request] [version]
  version          optional; defaults to latest git tag
  --pull-request   open a PR to the tap after pushing
EOF
            exit 0
            ;;
        --pull-request) PULL_REQUEST=true ;;
        *) ARGS+=("$arg") ;;
    esac
done

set -euo pipefail

cd "$(dirname "$0")"

[ -f .env ] && source .env

if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"
fi

APP_NAME="Mamecase"
BREW_NAME="mamecase"
TARGET="aarch64-apple-darwin"
DIST_DIR="dist"
HOMEBREW_TAP_URL="${HOMEBREW_TAP_URL:-https://github.com/douglaslassance/homebrew-tap.git}"
HOMEBREW_REPO=$(echo "$HOMEBREW_TAP_URL" | sed 's|https://github.com/||' | sed 's|\.git$||')
HOMEBREW_DIR=$(basename "$HOMEBREW_TAP_URL" .git)
TAP_NAME=$(echo "$HOMEBREW_REPO" | sed 's|/homebrew-|/|')
CASK_FILE="Casks/${BREW_NAME:0:1}/${BREW_NAME}.rb"

VERSION="${ARGS[0]:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"
if [ -z "$VERSION" ]; then
    echo "❌ version required (pass as arg or create a git tag)"
    exit 1
fi

SHA_FILE="${DIST_DIR}/${BREW_NAME}-${VERSION}-${TARGET}.dmg.sha256"
if [ ! -f "$SHA_FILE" ]; then
    echo "❌ ${SHA_FILE} not found — run ./build.sh ${VERSION} first"
    exit 1
fi
SHA256=$(awk '{print $1}' "$SHA_FILE")

CASK_TEMPLATE="$(pwd)/cask.rb"
if [ ! -f "$CASK_TEMPLATE" ]; then
    echo "❌ ${CASK_TEMPLATE} not found"
    exit 1
fi

echo "▸ updating ${BREW_NAME} cask to ${VERSION}"

# Clone or refresh the tap as a sibling directory of the project.
cd ..
if [ -d "$HOMEBREW_DIR" ]; then
    cd "$HOMEBREW_DIR"
else
    git clone "$HOMEBREW_TAP_URL" "$HOMEBREW_DIR"
    cd "$HOMEBREW_DIR"
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$HOMEBREW_TAP_URL"
fi
git fetch upstream

DEFAULT_BRANCH=$(gh repo view "$HOMEBREW_REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")

git reset --hard "upstream/${DEFAULT_BRANCH}"

BRANCH="bump-${BREW_NAME}-${VERSION}"
git checkout -B "$BRANCH" "upstream/${DEFAULT_BRANCH}"

mkdir -p "$(dirname "$CASK_FILE")"
sed -e "s|{{VERSION}}|${VERSION}|g" \
    -e "s|{{SHA256}}|${SHA256}|g" \
    "$CASK_TEMPLATE" > "$CASK_FILE"

git --no-pager diff --stat "$CASK_FILE"
git add "$CASK_FILE"
git commit -m "${BREW_NAME} ${VERSION}"

# Local smoke test: tap the cloned dir, audit, install, uninstall.
TAP_CASK="${TAP_NAME}/${BREW_NAME}"
cleanup() {
    brew uninstall --cask "$TAP_CASK" 2>/dev/null || true
    brew untap --force "$TAP_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "▸ brew style/audit/install"
rm -f ~/Library/Caches/Homebrew/downloads/*${APP_NAME}* 2>/dev/null || true
brew untap --force "$TAP_NAME" 2>/dev/null || true
brew tap "$TAP_NAME" "$(pwd)"

brew style --fix "$CASK_FILE"
if ! git diff --quiet "$CASK_FILE"; then
    git add "$CASK_FILE"
    git commit --amend --no-edit
fi

brew audit ${AUDIT_FLAGS:-} "$TAP_CASK"
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask "$TAP_CASK"

cleanup
trap - EXIT

echo "▸ push ${BRANCH}"
git push --force origin "$BRANCH"

if [ "$PULL_REQUEST" = true ]; then
    REPO_INFO=$(gh repo view "$HOMEBREW_REPO" --json isFork,parent,defaultBranchRef)
    IS_FORK=$(echo "$REPO_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('isFork', False))")
    if [ "$IS_FORK" = "True" ]; then
        PARENT_SLUG=$(echo "$REPO_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['parent']['nameWithOwner'])")
        PR_BASE=$(gh repo view "$PARENT_SLUG" --json defaultBranchRef -q '.defaultBranchRef.name')
        OWNER=$(echo "$HOMEBREW_REPO" | cut -d/ -f1)
        PR_REPO="$PARENT_SLUG"
        PR_HEAD="${OWNER}:${BRANCH}"
    else
        PR_BASE="$DEFAULT_BRANCH"
        PR_REPO="$HOMEBREW_REPO"
        PR_HEAD="$BRANCH"
    fi
    gh pr create \
        --repo "$PR_REPO" \
        --head "$PR_HEAD" \
        --base "$PR_BASE" \
        --title "${BREW_NAME} ${VERSION}" \
        --body "Updates ${BREW_NAME} to version ${VERSION}.

- SHA256: ${SHA256}"
fi

echo "✓ done"
