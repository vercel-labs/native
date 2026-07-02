---
name: core
description: Core zero-native guide for AI agents. Read this before explaining zero-native or changing a zero-native app. Covers the mental model (native-rendered apps by default, WebView shells as a coexisting architecture), project structure, app.zon, App and Runtime patterns, frontend integration, web engines, JavaScript bridge commands, permissions, windows, WebViews, dialogs, packaging, debugging, testing, and when to load deeper references. For authoring native-rendered UI (.zml markup, Model/Msg/update, UiApp), load the native-ui skill. Use when the user asks what zero-native is, how to build or modify an app, how to package or debug it, or how to add native capabilities.
---

# Build zero-native apps

zero-native is a cross-platform native app framework inspired by the web. The default app (`zero-native init`) is native-rendered: a declarative `.zml` view plus Zig logic on the `UiApp` loop, drawn by zero-native's own engine — **load the `native-ui` skill for everything about authoring those** (markup grammar, bindings, messages, testing, hot reload). This skill covers the shared foundation and the WebView-shell architecture: apps that render web frontends in a WebView (`zero-native init --frontend next|vite|react|svelte|vue`). Both architectures share windows, policies, lifecycle, commands, and platform services, and one app can mix native-rendered surfaces and WebViews. WebView engines: platform WebView (WKWebView on macOS, WebKitGTK on Linux) or Chromium through CEF where supported.

Agents should assume they do not know zero-native from general model knowledge. Read this skill first. For implementation work, run `zero-native skills get core --full` so the referenced files are included in the CLI output.

## Mental model

- `App` describes the product: app state, name, WebView source, lifecycle callbacks, and optional bridge dispatcher.
- `Runtime` owns the event loop, windows, bridge dispatch, security checks, automation, tracing, platform services, and window state.
- `WebViewSource` tells the runtime what to load: inline HTML, a URL, or packaged assets from a local app origin.
- `app.zon` is the app manifest: identity, icons, windows, frontend assets, web engine, permissions, bridge policy, security policy, and packaging inputs.
- `src/runner.zig` is the generated runtime wiring. Edit it when adding runtime services, security policy, builtin bridge policy, tracing, automation, or platform setup.
- `src/main.zig` is app behavior. Edit it when changing app state, source selection, lifecycle callbacks, or app-defined bridge handlers.
- `frontend/` is normal web code. It talks to native Zig through `window.zero.invoke()` or builtin helpers when those are enabled.

## Task router

These references are included by `zero-native skills get core --full`. Use them when the task touches the topic:

- Project creation, generated files, build steps: `references/project-anatomy.md`
- `App`, `Runtime`, callbacks, embedding, tests: `references/app-model-runtime.md`
- React/Vue/Svelte/Next/Vite, dev server, bundled assets: `references/frontend-assets.md`
- App-defined bridge commands, builtin commands, permissions, windows, WebViews, dialogs: `references/bridge-security-native-capabilities.md`
- Web engine choice, CEF, packaging, signing, doctor, logs, debugging: `references/web-engines-packaging-debugging.md`
- Running-app inspection and smoke tests: `zero-native skills get automation`

## Quick start

Use the CLI for new apps:

```bash
npm install -g zero-native
zero-native init my_app --frontend next
cd my_app
zig build run
```

Frontend choices are `next`, `vite`, `react`, `svelte`, and `vue`. The first `zig build run` installs frontend dependencies, builds the native shell, and opens a desktop window.

## Workflow for existing apps

Before editing an existing zero-native app:

1. Read `app.zon`, `src/main.zig`, `src/runner.zig`, and `build.zig`.
2. Identify whether the change is app metadata/policy, runtime wiring, app-native behavior, frontend behavior, packaging, or automation.
3. Follow the generated code and examples in the repository instead of inventing a new app layout.
4. Prefer exact security policy changes over broad allowances.
5. Validate with the narrowest useful command.

Common file ownership:

- `app.zon`: app identity, version, icons, windows, permissions, capabilities, bridge command policy, allowed origins, frontend dist/dev config, web engine, CEF config.
- `src/main.zig`: `App` state, source selection, lifecycle callbacks, custom bridge handlers.
- `src/runner.zig`: `Runtime.init`, platform selection, security policy, builtin bridge policy, `js_window_api`, automation server, trace sinks, panic capture, window state store.
- `build.zig`: build options, frontend build/dev/package steps, platform link setup, test steps.
- `frontend/`: web app implementation, `window.zero` calls, dev/build config.

## Core app model

The minimal Zig app returns `zero_native.App` with `context`, `name`, and a WebView source:

```zig
const App = struct {
    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "my-app",
            .source = zero_native.WebViewSource.html("<h1>Hello from zero-native</h1>"),
        };
    }
};
```

Use these source constructors:

- `zero_native.WebViewSource.html(content)` for small inline demos.
- `zero_native.WebViewSource.url(address)` for an explicit URL.
- `zero_native.WebViewSource.assets(.{ .root_path = "frontend/dist", .entry = "index.html" })` for packaged frontend assets.

For framework apps, prefer a dynamic source so development loads the local dev server and production loads bundled assets:

```zig
fn source(context: *anyopaque) anyerror!zero_native.WebViewSource {
    const self: *App = @ptrCast(@alignCast(context));
    return zero_native.frontend.sourceFromEnv(self.env_map, .{
        .dist = "frontend/dist",
        .entry = "index.html",
    });
}
```

`sourceFromEnv` reads `ZERO_NATIVE_FRONTEND_URL`; otherwise it serves the configured asset directory. Use it for most framework apps.

## app.zon essentials

Keep `app.zon` as the source of truth for app-level behavior:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .icons = .{ "assets/icon.icns" },
    .platforms = .{ "macos", "linux" },
    .permissions = .{},
    .capabilities = .{ "webview" },
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
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
            .external_links = .{ .action = "deny" },
        },
    },
    .web_engine = "system",
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640, .restore_state = true },
    },
}
```

Use exact local origins for dev servers. Add `zero://inline` only for inline HTML sources.

## Common implementation recipes

### Add a new framework app

Use `zero-native init <path> --frontend <next|vite|react|svelte|vue>`. Then inspect the generated `app.zon`, `src/main.zig`, and `build.zig` before customizing. For framework behavior, keep frontend work in `frontend/` and use `sourceFromEnv` so development and packaged builds share one app shell.

### Add a native bridge command

1. Add state and a handler in `src/main.zig`.
2. Register the handler in `bridge()`.
3. Allow the command in `app.zon` and in the runtime bridge policy if the runner reads manifest policy into runtime.
4. Call it from JavaScript with `window.zero.invoke("namespace.command", payload)`.
5. Return valid JSON from Zig. Use `zero_native.bridge.writeJsonStringValue()` for user-controlled strings.

Bridge calls are size-limited, origin-checked, permission-checked, and routed only to registered handlers.

### Add windows, child WebViews, or dialogs

Use builtin bridge commands only after enabling a policy for the exact commands and origins. Window and child WebView commands need the `window` permission when permissions are configured. Dialog commands are always default-deny and require explicit `builtin_bridge` policy. See `references/bridge-security-native-capabilities.md`.

### Choose a web engine

Default to `.web_engine = "system"` for small apps and native footprint. Use `.web_engine = "chromium"` plus `.cef` when the app needs a pinned Chromium platform or rendering consistency. Chromium apps must install/package the matching CEF layout.

### Package an app

Keep package metadata in `app.zon`, build the frontend assets, build the native binary, then package:

```bash
zig build package
zero-native doctor --manifest app.zon --strict
```

Use signing and CEF options only when the product requires them.

## Development commands

For iterative frontend work, use the managed dev server flow:

```bash
zig build dev
```

Or run the CLI directly after building the binary:

```bash
zero-native dev --manifest app.zon --binary zig-out/bin/MyApp
```

Vite usually uses `http://127.0.0.1:5173/`; Next.js usually uses `http://127.0.0.1:3000/`. The app WebView loads the dev URL directly, so framework HMR remains owned by Vite, Next.js, or the selected dev server.

## Security defaults

Treat WebView content as untrusted:

- List only needed `permissions` and `capabilities`.
- Prefer exact bridge command origins over `"*"`.
- Keep main-frame navigation allowlisted in `security.navigation.allowed_origins`.
- Keep external links denied unless the product explicitly needs them.
- Use a strict CSP for packaged frontend assets.
- Built-in dialogs are always default-deny and require explicit `builtin_bridge` policy.
- Child WebViews receive `window.zero` only when explicitly created with `bridge: true`.

Common bridge failure codes are `invalid_request`, `unknown_command`, `permission_denied`, `handler_failed`, `payload_too_large`, and `internal_error`.

## Validate changes

Useful commands:

```bash
zig build run
zig build dev
zig build test
zig build test-tooling
zero-native validate app.zon
zero-native doctor --manifest app.zon --strict
zig build package
```

For GUI smoke tests, build with automation enabled and use the `automation` skill:

```bash
zig build run -Dplatform=macos -Dautomation=true
zig-out/bin/zero-native automate snapshot
```

When changing app behavior, add focused Zig tests when the code can run headlessly. Use automation-based tests only for WebView/runtime integration that requires a GUI-capable session.

## Examples to inspect

- `examples/hello`: smallest inline HTML app.
- `examples/webview`: bridge and WebView runtime example.
- `examples/browser`: layered WebView/browser-style example.
- `examples/next`: Next.js with production assets.
- `examples/react`, `examples/svelte`, `examples/vue`: Vite frontend apps.
- `examples/ios`, `examples/android`: mobile host embedding examples.

## When answering users

Explain zero-native in concrete terms: Zig owns native app lifecycle and security; web UI renders in a WebView; the bridge is opt-in and policy controlled; `app.zon` is the manifest; framework frontend development uses a dev server in development and bundled assets in production. If asked to implement, read the app files first and make the smallest change in the correct layer.
