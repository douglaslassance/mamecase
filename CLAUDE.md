# MAMECASE conventions

## Commit messages

- Single line, imperative mood ("Add foo", not "Added foo" or "Adds foo").
- Up to 72 characters total.
- No `Co-Authored-By` lines, no trailers, no emoji.

## Bundling

Run `scripts/bundle.sh` to produce `Mamecase.app` at the repo root from
a release build. The bundle is gitignored — only the script is tracked.
