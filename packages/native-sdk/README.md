# @native-sdk/cli

The command line for [Native SDK](https://native-sdk.dev): the complete toolkit for building native desktop applications.

Apps are authored in TypeScript + declarative Native markup by default. The TypeScript core compiles ahead of time to native code, and Native SDK's own engine draws every pixel into real OS windows — no browser, WebView, JS runtime, or interpreter in the binary. Zig is a first-class app-core alternative by explicit choice and the language the toolkit itself is built in.

## Install

```bash
npm install -g @native-sdk/cli
```

The install runs no scripts: the `native` binary arrives as a per-platform optional dependency (`@native-sdk/cli-<platform>`), and this package carries the SDK source your apps build against, so `native init` and `native dev` work offline after install. The pinned Zig toolchain is fetched into `~/.native/toolchains/` on first build unless a compatible `zig` is already on your PATH.

## Use

```bash
native init my_app
cd my_app
native dev
```

A native window opens with a working counter. The primary scaffold is three files of truth and no build config: `src/core.ts` (`Model`, `Msg`, `update`), `src/app.native` (the UI), and `app.json` (the manifest, with JSON Schema completion). Existing `app.zon` manifests remain supported. `native dev|build|test` own the generated build; `src/app.native` hot-reloads while the app runs, keeping your state; `native dev --core` runs the TypeScript logic loop under node; and `native check` validates the core and every view in milliseconds without building. Prefer a Zig core? Use `native init my_app --template zig-core`.

When part of your product is the web, WebView surfaces coexist with the native canvas; web-frontend scaffolds (`--frontend next`, `--frontend vite`, and more) install their generated frontend dependencies automatically on first run.

Read the full guide at [native-sdk.dev/quick-start](https://native-sdk.dev/quick-start).

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

The full documentation is at [native-sdk.dev](https://native-sdk.dev) — the [quick start](https://native-sdk.dev/quick-start), [TypeScript cores](https://native-sdk.dev/typescript), [native UI authoring](https://native-sdk.dev/native-ui), [app model](https://native-sdk.dev/app-model), [components](https://native-sdk.dev/components), [testing](https://native-sdk.dev/testing), [automation](https://native-sdk.dev/automation), [capabilities](https://native-sdk.dev/capabilities), [packaging](https://native-sdk.dev/packaging), and [platform support](https://native-sdk.dev/platform-support).

Native SDK is pre-1.0 and Apache-2.0 licensed; the source lives at [github.com/vercel-labs/native](https://github.com/vercel-labs/native).
