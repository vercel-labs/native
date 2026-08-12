# Project Anatomy

Use this when creating, orienting in, or restructuring a Native SDK app.

## Generated project files

A default zero-config app ships no build files at all. Its authored files are `app.zon`, `src/core.ts`, and `src/app.native` (+ `assets/`). `native check` validates the TypeScript core, markup, and manifest without generating a build graph; `native dev|test|build` compile the app to native code and synthesize the build graph into `.native/build/` (gitignored). `build.zig`/`build.zig.zon` appear only in apps that own their build (`native eject`, the `--full` scaffold, or an expanded example). A Zig core is an explicit alternative created with `--template zig-core`, not something to infer from the SDK's implementation or older examples.

Files by path:

- `build.zig`: Zig build graph. Expanded scaffolds expose platform selection, trace mode, debug overlay, automation, JS bridge, web engine overrides, frontend install/build/dev steps, tests, and package steps.
- `build.zig.zon`: Zig package manifest and dependency declaration.
- `app.zon`: app manifest read by CLI/build/package/doctor tooling.
- `src/core.ts`: the default app core — `Model`, `Msg`, `update`, pure helpers, effects (`Cmd`), and subscriptions (`Sub`).
- `src/app.native`: the default app view — elements, layout, bindings, and typed message dispatch.
- `src/main.zig`: present for an explicitly selected Zig core or lower-level WebView/runtime app; app state, `app()` method, source resolver, optional bridge dispatcher, lifecycle callbacks.
- `src/runner.zig`: present when the app owns lower-level platform/runtime setup: native backend, trace sinks, panic capture, log paths, state store, security policy, builtin bridge policy, automation.
- `assets/`: icons and other package resources.
- `frontend/`: framework app when using Next, Vite, React, Svelte, or Vue.

## app.zon responsibilities

Keep product-level metadata and policies in `app.zon`:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .icons = .{"assets/icon.png"},
    .platforms = .{ "macos", "linux" },
    .permissions = .{ "window" },
    .capabilities = .{ "webview", "js_bridge" },
    .bridge = .{
        .commands = .{
            .{ .name = "native.ping", .origins = .{ "zero://app" } },
        },
    },
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
            .external_links = .{ .action = "deny" },
        },
    },
    .frontend = .{
        .dist = "frontend/dist",
        .entry = "index.html",
        .spa_fallback = true,
        .dev = .{
            .url = "http://127.0.0.1:5173/",
            .command = .{ "npm", "--prefix", "frontend", "run", "dev", "--", "--host", "127.0.0.1" },
            .ready_path = "/",
            .timeout_ms = 30000,
        },
    },
    .web_engine = "system",
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640, .restore_state = true },
    },
}
```

Important manifest fields:

- `id`: reverse-DNS bundle identifier, at most 128 bytes. Used for bundle metadata, credential service namespacing, and log/state paths.
- `name`: short machine name.
- `display_name`: human app name — shown by the application menu, Dock, app switcher, and About panel in dev runs and packaged bundles alike.
- `description`: optional one-line About-panel description (max 256 bytes, single line).
- `version`: package and bundle version — also shown in the About panel.
- `icons`: package resources.
- `platforms`: package targets.
- `permissions`: runtime grants checked by bridge and builtin commands.
- `capabilities`: broad feature declarations.
- `bridge.commands`: app-defined command allowlist.
- `security.navigation.allowed_origins`: main-frame navigation allowlist.
- `security.navigation.external_links`: external link policy.
- `frontend`: production asset and dev server config.
- `web_engine`: `system` or `chromium`.
- `cef`: CEF layout config for Chromium.
- `windows`: initial window definitions.
- `dmg`: optional macOS disk-image art direction; use the zero-config drag-to-Applications layout, override its background/geometry, or declare a positioned `items` list for arbitrary files and links.

## Build steps to know

Common zero-config steps:

```bash
native check
native dev
native test
native build
native package --target macos --archive
```

Equivalent/common owned-build steps:

```bash
zig build run
zig build dev
zig build test
zig build package
zig build frontend-install
zig build frontend-build
```

Repository-level useful steps:

```bash
zig build test
zig build test-tooling
zig build test-webview-smoke -Dplatform=macos
zig build test-package-cef-layout -Dplatform=macos
```

## Layering rule

- If changing app identity, packaging inputs, permissions, origins, windows, frontend dist/dev paths, or web engine, update `app.zon`.
- If changing default app state, messages, transitions, effects, subscriptions, or derived bindings, update `src/core.ts` and follow the `ts-core` skill.
- If changing the default app UI, update `src/app.native` and follow the `native-ui` skill.
- If changing runtime services, platform setup, automation, logging, security wiring, or builtin bridge policy, update `src/runner.zig`.
- If an existing lower-level/Zig app changes native lifecycle callbacks, bridge handlers, source selection, or Zig-core behavior, update its `src/main.zig`.
- If changing UI, routes, CSS, or web calls, update `frontend/`.

Do not add `src/main.zig`, `src/runner.zig`, or an owned build merely to implement ordinary behavior in a default TypeScript app. Do not put package metadata in app state or bypass `app.zon` policy for convenience.
