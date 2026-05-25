# Mamecase conventions

## Commit messages

- Single line, imperative mood ("Add foo", not "Added foo" or "Adds foo").
- Up to 72 characters total.
- No `Co-Authored-By` lines, no trailers, no emoji.

## Bundling

Run `./bundle.sh` to produce `Mamecase.app` at the repo root from a
release build. The bundle is gitignored — only the script is tracked.

## Releasing

Tag (`git tag v0.x.y && git push --tags`), then from the repo root:

1. `./build.sh` — bundles, Developer ID-signs, builds + notarizes the
   DMG, writes `dist/mamecase-<version>-aarch64-apple-darwin.dmg` and
   a `.sha256` sidecar.
2. `./upload_build.sh` — uploads those assets to the matching GitHub
   Release (`vX.Y.Z`), creating it if missing.
3. `./submit_build.sh [--pull-request]` — bumps the
   `douglaslassance/homebrew-tap` cask, runs `brew audit`/`install`
   locally, pushes the branch, and optionally opens a PR.

All three scripts read `.env` at the repo root (gitignored). Required
keys: `APPLE_SIGNING_IDENTITY`, `NOTARIZATION_KEY_ID`,
`NOTARIZATION_ISSUER_ID`, `NOTARIZATION_KEY` (base64 .p8). Optional:
`GITHUB_PERSONAL_ACCESS_TOKEN`, `HOMEBREW_TAP_URL`.
