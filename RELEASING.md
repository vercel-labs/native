# Releasing

Releases are manual, single-PR affairs. The maintainer controls the changelog voice and format.

To prepare a release:

1. Create a branch (e.g. `prepare-v1.2.0`)
2. Bump the version in `packages/native-sdk/package.json`
3. Run `npm --prefix packages/native-sdk run version:sync` to update all version references
4. Run `scripts/changelog-merge.sh` to fold any pending `changelog.d/` fragments into the `## Unreleased` section
5. Write the changelog entry in `CHANGELOG.md`, wrapped in `<!-- release:start -->` and `<!-- release:end -->` markers
6. Populate the entry's `### Contributors` from commit authors and `Co-authored-by` trailers in the release range, using GitHub handles when available; this marked block is also the GitHub release body
7. Remove the `<!-- release:start -->` and `<!-- release:end -->` markers from the previous release entry; only the latest release should have markers
8. Open a PR and merge to `main`

CI compares the version in `packages/native-sdk/package.json` to what's on npm. If it differs, it cross-builds the CLI for every platform, creates the GitHub release with the binaries, publishes the per-platform binary packages (`packages/native-sdk/npm/*`), and publishes `@native-sdk/cli` last — so the main package only lands once every binary package it pins is live. If npm already has the version but the GitHub release is missing assets, CI recreates the GitHub release from the marked changelog entry.

Publishing uses npm trusted publishing (OIDC) — there is no npm token secret. One-time setup: on npmjs.com, each of the nine packages (`@native-sdk/cli` plus the eight `@native-sdk/cli-*` platform packages under `packages/native-sdk/npm/*`) must have a GitHub Actions trusted publisher configured with repository `vercel-labs/native`, workflow `release.yml`, and environment `Release`. Every publish runs with `--provenance`. If a package is missing its trusted-publisher configuration, `npm publish` fails loudly with an OIDC authentication error for that package.
