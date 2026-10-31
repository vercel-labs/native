# @native-sdk/cli

The command-line tools for [Native SDK](https://native-sdk.dev). Create, build, test, and package native desktop applications with TypeScript and Native markup.

The default app core uses a checked TypeScript subset and compiles to native code. Native markup defines the interface, which the toolkit renders in OS windows. Apps can also use Zig cores or embed web content.

## Install

```bash
npm install -g @native-sdk/cli
```

The `native` binary arrives as a per-platform optional dependency (`@native-sdk/cli-<platform>`). Installation also downloads the exact scriptc release, verifies its checksum, and installs the matching compiler API and runtime packs into `~/.native/toolchains/scriptc/`. This package carries the SDK source your apps build against, so `native init` and `native dev` work offline after installation. If npm install scripts are disabled, run `node packages/core/scripts/install_scriptc.mjs` from the installed CLI package before building. `NATIVE_SDK_SCRIPTC_CACHE` selects another toolchain cache directory. The pinned Zig toolchain is fetched into `~/.native/toolchains/` on first build unless a compatible `zig` is already on your PATH.

## Use

```bash
native init my_app
cd my_app
native dev
```

The generated counter app uses `src/core.ts` for its model and updates, `src/app.native` for its view, and `app.json` for configuration. Existing `app.zon` manifests remain supported.

`native dev` reloads markup while preserving app state. Core changes rebuild and restart the app. Use `native dev --core` to exercise TypeScript logic under Node.js without a window, `native check` to validate the project, and `native build` for a release binary. Use `--template zig-core` with `native init` to create a Zig core instead.

When part of your product is the web, WebView surfaces coexist with the native canvas; web-frontend scaffolds (`--frontend next`, `--frontend vite`, and more) install their generated frontend dependencies automatically on first run.

Read the full guide at [native-sdk.dev/quick-start](https://native-sdk.dev/docs/quick-start).

## Commands

| Command | Description |
|---------|-------------|
| `native init [path] [--template <ts-core\|zig-core>] [--frontend <native\|next\|vite\|react\|svelte\|vue>] [--full]` | Scaffold a new Native SDK app (TypeScript core + Native markup by default) |
| `native dev [dir]` | Build and run the app (markup hot reload; managed frontend dev server when configured) |
| `native build [dir]` | Build a ReleaseFast binary into `zig-out/bin/` |
| `native test [dir]` | Run the app's test suite |
| `native check [dir]` | Validate `src/**.native` markup and `app.json`/`app.zon` against the model contract |
| `native markup check\|lsp` | Check individual markup files, or serve diagnostics, completion, and hover to your editor |
| `native eject [dir]` | Write an owned build.zig/build.zig.zon into the app |
| `native doctor` | Check host environment, WebView, manifest, and CEF |
| `native validate` | Validate `app.json` (or `app.zon`) against the manifest schema |
| `native package` | Package the app for distribution |
| `native bundle-assets` | Copy frontend assets into the build output |
| `native automate` | Drive a running app: snapshots, widgets, assertions, screenshots, record/replay |
| `native skills list\|get <name>` | List or print the built-in AI agent skills |
| `native version` | Print the native version |

## More

The full documentation is at [native-sdk.dev](https://native-sdk.dev) — the [quick start](https://native-sdk.dev/docs/quick-start), [TypeScript cores](https://native-sdk.dev/typescript), [native UI authoring](https://native-sdk.dev/native-ui), [app model](https://native-sdk.dev/app-model), [components](https://native-sdk.dev/components), [testing](https://native-sdk.dev/docs/testing), [automation](https://native-sdk.dev/docs/automation), [capabilities](https://native-sdk.dev/docs/capabilities), [packaging](https://native-sdk.dev/docs/packaging), and [platform support](https://native-sdk.dev/docs/platform-support).

Native SDK is pre-1.0 and Apache-2.0 licensed; the source lives at [github.com/vercel-labs/native](https://github.com/vercel-labs/native).
