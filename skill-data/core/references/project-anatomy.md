# Project Anatomy

Use this when creating, orienting in, or restructuring a Native SDK app.

## Generated project files

A zero-config app ships no build files at all — just `app.zon` + `src/` (+ `assets/`); the `native dev|test|build` verbs synthesize the build graph into `.native/build/` (gitignored). `build.zig`/`build.zig.zon` appear only in apps that own their build (`native eject`, the `--full` scaffold, or an expanded example):

- `build.zig`: Zig build graph. Expanded scaffolds expose platform selection, trace mode, debug overlay, automation, JS bridge, web engine overrides, frontend install/build/dev steps, tests, and package steps.
- `build.zig.zon`: Zig package manifest and dependency declaration.
- `app.zon`: app manifest read by CLI/build/package/doctor tooling.
- `src/main.zig`: app state, `app()` method, source resolver, optional bridge dispatcher, lifecycle callbacks.
- `src/runner.zig`: platform and runtime setup: native backend, trace sinks, panic capture, log paths, state store, security policy, builtin bridge policy, automation.
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

- `id`: reverse-DNS bundle identifier. Used for bundle metadata and log/state paths.
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

## Build steps to know

Common generated steps:

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
- If changing runtime services, platform setup, automation, logging, security wiring, or builtin bridge policy, update `src/runner.zig`.
- If changing native business behavior, lifecycle callbacks, bridge handlers, or source selection, update `src/main.zig`.
- If changing UI, routes, CSS, or web calls, update `frontend/`.

Do not put package metadata in Zig app state unless the generated project already does that. Do not bypass `app.zon` policy for convenience.
