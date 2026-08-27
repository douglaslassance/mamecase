# Mamecase conventions

## Commit messages

- Single line, imperative mood ("Add foo", not "Added foo" or "Adds foo").
- Up to 72 characters total.
- No `Co-Authored-By` lines, no trailers, no emoji.

## Releasing

The release pipeline lives in the `catapult` submodule and is configured
by `catapult.toml` at the repo root. `catapult/README.md` is the full
reference.

Tag first (`git tag v0.x.y && git push --tags`), then from the repo root:

```sh
./catapult/release.sh
```

That runs the whole flow for the `s3` and `homebrew` channels. It builds,
Developer ID-signs, notarizes and staples, writes the DMG, uploads it
along with the Sparkle appcast, and bumps the Homebrew cask.

Individual steps are available when only one is needed:

- `./catapult/build.sh` assembles `build/Mamecase.app` and produces a
  notarized `dist/mamecase-<version>-aarch64-apple-darwin.dmg` plus a
  `.sha256` sidecar.
- `./catapult/upload.sh` pushes the DMG and appcast.
- `./catapult/push_homebrew.sh` bumps the `douglaslassance/homebrew-tap`
  cask, optionally with `--pull-request`.

Every script sources `.env` at the repo root (gitignored). Copy
`catapult/env.example` for the list of keys.

To bump catapult, check out the new commit in the submodule and commit
the pointer:

```sh
cd catapult && git fetch && git checkout <sha> && cd .. && git add catapult
```

## Local builds

`build.sh` signs with Developer ID and uploads to Apple for
notarization, which is more than a local test needs. To get a runnable
`Mamecase.app` without either, run the same bundle steps with
`APPLE_SIGNING_IDENTITY` and the `NOTARIZATION_*` variables unset. The
script then falls back to an ad-hoc signature, which is enough to launch
locally but not to distribute.
