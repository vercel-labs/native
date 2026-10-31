# Contributing

Thanks for helping improve the Native SDK. This guide is for maintainers and contributors working on the toolkit repository itself.

For app author documentation, start at [native-sdk.dev](https://native-sdk.dev).

## Prerequisites

- [Zig 0.16.0+](https://ziglang.org/download/)
- Node.js with npm for the CLI package and generated frontend projects
- pnpm for the documentation site
- macOS for WKWebView and Chromium/CEF development
- Linux with GTK4 and WebKitGTK 6 for Linux system WebView development

## Local Checks

Run the toolkit tests:

```bash
zig build test
```

Validate the sample app manifest:

```bash
zig build validate
```

Build the WebView example against the system engine:

```bash
zig build test-webview-system-link
```

Run the WebView example:

```bash
zig build run-webview
```

Check the npm CLI package:

```bash
npm --prefix packages/native-sdk run version:check
npm --prefix packages/native-sdk run scripts:check
```

Check the documentation site:

```bash
pnpm --dir docs install --frozen-lockfile
pnpm --dir docs check
```

## Web Engine Development

The system WebView path is the default development loop:

```bash
zig build run-webview -Dweb-engine=system
```

For Chromium on macOS, install CEF and run with the Chromium engine:

```bash
native cef install
zig build run-webview -Dweb-engine=chromium
```

Useful Chromium smoke checks:

```bash
zig build test-webview-cef-smoke -Dplatform=macos -Dweb-engine=chromium
zig build test-package-cef-layout -Dplatform=macos
```

## Packaging Development

Create a local package artifact:

```bash
zig build package
```

Package explicitly through the CLI:

```bash
native package --target macos --manifest app.zon --assets assets --binary zig-out/lib/libnative-sdk.a
```

For Chromium packages, configure `.web_engine = "chromium"` and `.cef` in `app.zon`, or use temporary `--web-engine` and `--cef-dir` overrides while testing.

Verify an ad-hoc signed package's code signature survives packaging intact (macOS; skips loudly on hosts without `codesign`):

```bash
zig build test-package-signing
```

## Automation Development

Enable automation in a build:

```bash
zig build run-webview -Dautomation=true
```

Interact with the running app:

```bash
native automate wait
native automate list
native automate bridge '{"id":"ping","command":"native.ping","payload":null}'
```

Automation writes artifacts under `.zig-cache/native-sdk-automation`.


## Making a Pull Request

Branch from `main` (fork first if you don't have push access), keep the change focused, and run the tiered local gate before opening the PR:

```bash
scripts/gate.sh fast    # root suites + the example suites your diff touches
```

Do not edit `CHANGELOG.md` as part of a feature or fix PR; the release agent writes the complete entry from the release-range history. Open the PR against `main` describing what changed and why; for larger changes, open an issue first so the design can be discussed.

Commits must be cryptographically signed (`git commit -S`, or set `commit.gpgsign = true`) so they show as **Verified** — the `Signed-off-by` trailer from `git commit -s` is a DCO attestation, not a signature.
