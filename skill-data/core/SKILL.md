---
name: core
description: Core Native SDK guide for AI agents. Read this before explaining the Native SDK or changing a Native SDK app. Establishes TypeScript + Native markup as the default app-authoring path, routes default app work to the native-ui and ts-core skills, and covers the shared foundation: project structure, app.json and legacy app.zon, lower-level App and Runtime patterns, frontend integration, web engines, JavaScript bridge commands, permissions, windows, WebViews, dialogs, packaging, debugging, and testing. Use when the user asks what the Native SDK is, how to build or modify an app, how to package or debug it, or how to add native capabilities.
---

# Build Native SDK apps

The Native SDK is a cross-platform native app toolkit inspired by the web. The default app (`native init`) is native-rendered and authored as a declarative Native markup view (`src/app.native`) plus a TypeScript app core (`src/core.ts`). The core is checked and compiled ahead of time to native code; no JS runtime ships in the binary. **For default app implementation, load both the `native-ui` and `ts-core` skills.** Zig is the implementation language of the toolkit and a first-class app-core choice via `--template zig-core`, not the default app-authoring language.

This skill covers the shared foundation and lower-level architectures: apps that explicitly choose a Zig core, runtime extensions, and apps that render web frontends in a WebView (`native init --frontend next|vite|react|svelte|vue`). Native-rendered surfaces and WebViews share windows, policies, lifecycle, commands, and platform services, and one app can mix them. WebView engines are the platform WebView (WKWebView on macOS, WebKitGTK on Linux) or Chromium through CEF where supported.

Agents should assume they do not know the Native SDK from general model knowledge. Read this skill first. For ordinary app implementation, load `native-ui` and `ts-core`; for shared/runtime, WebView, packaging, or native-capability work, run `native skills get core --full` so the referenced files are included in the CLI output.

## Mental model

- The default app has three files of truth: `src/core.ts` (`Model`, `Msg`, `update`), `src/app.native` (UI), and `app.json` (manifest).
- Native markup binds model values and dispatches typed messages; only `update` changes state.
- The TypeScript core compiles to native code. Node is a build/check/dev tool, not an app runtime.
- `App` is the lower-level product/runtime interface used by generated wiring, Zig-core apps, WebView shells, and extensions.
- `Runtime` owns the event loop, windows, bridge dispatch, security checks, automation, tracing, platform services, and window state.
- `WebViewSource` tells the runtime what to load: inline HTML, a URL, or packaged assets from a local app origin.
- `app.json` is the default app manifest: identity, icons, windows, frontend assets, web engine, permissions, bridge policy, security policy, and packaging inputs. `app.zon` remains supported.
- `src/runner.zig` and `src/main.zig` appear only when an app explicitly owns lower-level Zig wiring (for example a `zig-core` app or a WebView shell). `--full` makes a TypeScript app own `build.zig` but still does not give it Zig app logic. Do not add Zig sources to a default TypeScript app merely because SDK examples contain them.
- `frontend/` is normal web code. It talks to native Zig through `window.zero.invoke()` or builtin helpers when those are enabled.

## Task router

These references are included by `native skills get core --full`. Use them when the task touches the topic:

- Project creation, generated files, build steps: `references/project-anatomy.md`
- Default TypeScript core authoring, checker rules, effects, subscriptions, modules: `native skills get ts-core`
- Native markup, bindings, messages, hot reload, view testing: `native skills get native-ui`
- `App`, `Runtime`, callbacks, embedding, tests: `references/app-model-runtime.md`
- React/Vue/Svelte/Next/Vite, dev server, bundled assets: `references/frontend-assets.md`
- App-defined bridge commands, builtin commands, permissions, windows, WebViews, dialogs: `references/bridge-security-native-capabilities.md`
- Web engine choice, CEF, packaging, signing, doctor, logs, debugging: `references/web-engines-packaging-debugging.md`
- Running-app inspection and smoke tests: `native skills get automation`
- `zig build` fails on std APIs ("no member named 'cwd'", ArrayList `init`): `native skills get zig` — the Zig 0.16 idioms, indexed by compile error

## Quick start

Use the CLI for new apps:

```bash
npm install -g @native-sdk/cli
native init my_app
cd my_app
native dev
```

This creates `src/core.ts`, `src/app.native`, and `app.json`; a native window opens with `native dev`. Use `native init my_app --template zig-core` only when the user chooses Zig. Frontend choices (`--frontend next|vite|react|svelte|vue`) are the separate WebView migration/integration path.

## Workflow for existing apps

Before editing an existing Native SDK app:

1. Read `app.json` or `app.zon` and inspect `src/` before assuming a core language. Read `src/core.ts` + `src/app.native` for the default path; read `src/main.zig`, `src/runner.zig`, and `build.zig` only when they exist.
2. Identify whether the app is TypeScript + Native markup (default), an explicitly chosen Zig core, or a WebView frontend, then identify the layer the change belongs to.
3. Follow the generated code and examples in the repository instead of inventing a new app layout.
4. Prefer exact security policy changes over broad allowances.
5. Validate with the narrowest useful command.

Common file ownership:

- `app.json` / `app.zon`: app identity, version, icons, windows, permissions, capabilities, bridge command policy, allowed origins, frontend dist/dev config, web engine, CEF config.
- `src/core.ts`: default app state and behavior — `Model`, `Msg`, `update`, pure helpers, `Cmd`, and `Sub`.
- `src/app.native`: default app UI — elements, layout, bindings, and message dispatch.
- `src/main.zig`: explicitly chosen Zig-core logic or lower-level `App` behavior, source selection, lifecycle callbacks, and custom bridge handlers.
- `src/runner.zig`: `Runtime.init`, platform selection, security policy, builtin bridge policy, `js_window_api`, automation server, trace sinks, panic capture, window state store.
- `build.zig`: build options, frontend build/dev/package steps, platform link setup, test steps.
- `frontend/`: web app implementation, `window.zero` calls, dev/build config.

## Lower-level WebView app model (advanced)

This is not the default app-authoring path. A lower-level Zig/WebView shell returns `native_sdk.App` with `context`, `name`, and a WebView source:

```zig
const App = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "my-app",
            .source = native_sdk.WebViewSource.html("<h1>Hello from Native SDK</h1>"),
        };
    }
};
```

Use these source constructors:

- `native_sdk.WebViewSource.html(content)` for small inline demos.
- `native_sdk.WebViewSource.url(address)` for an explicit URL.
- `native_sdk.WebViewSource.assets(.{ .root_path = "frontend/dist", .entry = "index.html" })` for packaged frontend assets.

For framework apps, prefer a dynamic source so development loads the local dev server and production loads bundled assets:

```zig
fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
    const self: *App = @ptrCast(@alignCast(context));
    return native_sdk.frontend.sourceFromEnv(self.env_map, .{
        .dist = "frontend/dist",
        .entry = "index.html",
    });
}
```

`sourceFromEnv` reads `NATIVE_SDK_FRONTEND_URL`; otherwise it serves the configured asset directory. Use it for most framework apps.

## app.json essentials

Keep `app.json` as the source of truth for app-level behavior. Existing `app.zon` projects use the same fields in ZON syntax.

```json
{
  "$schema": "https://native-sdk.dev/schemas/app.schema.json",
  "id": "com.example.my-app",
  "name": "my-app",
  "display_name": "My App",
  "description": "One line about the app, shown in the About panel.",
  "version": "0.1.0",
  "icons": ["assets/icon.png"],
  "platforms": ["macos", "linux"],
  "permissions": [],
  "capabilities": ["webview"],
  "frontend": {
    "dist": "frontend/dist",
    "entry": "index.html",
    "spa_fallback": true,
    "dev": {
      "url": "http://127.0.0.1:5173/",
      "command": ["npm", "--prefix", "frontend", "run", "dev", "--", "--host", "127.0.0.1"],
      "ready_path": "/",
      "timeout_ms": 30000
    }
  },
  "security": {
    "navigation": {
      "allowed_origins": ["zero://app", "http://127.0.0.1:5173"],
      "external_links": { "action": "deny" }
    }
  },
  "web_engine": "system",
  "windows": [
    { "label": "main", "title": "My App", "width": 960, "height": 640, "restore_state": true }
  ]
}
```

Legacy ZON equivalent:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .description = "One line about the app, shown in the About panel.",
    .version = "0.1.0",
    .icons = .{"assets/icon.png"},
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

Use `native init <path> --frontend <next|vite|react|svelte|vue>`. Then inspect the generated `app.json`, `src/main.zig`, and `build.zig` before customizing. For framework behavior, keep frontend work in `frontend/` and use `sourceFromEnv` so development and packaged builds share one app shell.

### Add a native bridge command

1. Add state and a handler in `src/main.zig`.
2. Register the handler in `bridge()`.
3. Allow the command in the app manifest and in the runtime bridge policy if the runner reads manifest policy into runtime.
4. Call it from JavaScript with `window.zero.invoke("namespace.command", payload)`.
5. Return valid JSON from Zig. Use `native_sdk.bridge.writeJsonStringValue()` for user-controlled strings.

Bridge calls are size-limited, origin-checked, permission-checked, and routed only to registered handlers.

### Add windows, child WebViews, or dialogs

Use builtin bridge commands only after enabling a policy for the exact commands and origins. Window and child WebView commands need the `window` permission when permissions are configured. Dialog commands are always default-deny and require explicit `builtin_bridge` policy. See `references/bridge-security-native-capabilities.md`.

### Choose a web engine

Default to `.web_engine = "system"` for small apps and native footprint. Use `.web_engine = "chromium"` plus `.cef` when the app needs a pinned Chromium platform or rendering consistency. Chromium apps must install/package the matching CEF layout.

### Package an app

Zero-config apps package WITHOUT ejecting — `native package` works directly on the zero-config build (`native eject` is only for owning the build files, never a packaging prerequisite):

```bash
native build
native package --target macos --archive
```

On macOS, `--archive` adds a zero-config drag-to-Applications DMG with a generated 1×/2× Retina background. The optional `app.zon` `.dmg` block controls its volume name, PNG/JPEG/TIFF background, usable Finder canvas/icon geometry, and Applications link. An adjacent `name@2x.png`/`.jpg` is discovered automatically. Use `.dmg.items` only for a fully art-directed list: exactly one `app`, plus optional `applications`, project-relative `file`, and absolute `link` entries, each with its own icon-center position.

Apps that own their build (ejected or scaffolded `--full`) wire the same step into the build graph: keep package metadata in the app manifest, build the frontend assets, build the native binary, then package:

```bash
zig build package
native doctor --manifest app.json --strict
```

Use signing and CEF options only when the product requires them.

## Development commands

For a default TypeScript + Native markup app, use:

```bash
native check
native dev
native dev --core
native test
```

For iterative WebView-frontend work in an app that owns its build, use the managed dev server flow:

```bash
zig build dev
```

Or run the CLI directly after building the binary:

```bash
native dev --manifest app.json --binary zig-out/bin/MyApp
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

Useful default-app commands:

```bash
native check
native test
native build
```

Useful SDK, Zig-core, and owned-build commands:

```bash
zig build run
zig build dev
zig build test
zig build test-tooling
native validate app.json
native doctor --manifest app.json --strict
zig build package
```

For an app that owns Zig code, run BOTH `zig build` and `zig build test` before calling a change done: Zig's lazy analysis means code only tests reference (or only `main()` reference) can sit broken under the other command alone. This Zig-specific requirement does not turn a default TypeScript app into a Zig app.

The toolkit requires Zig 0.16.0. When a build fails with "no member named" errors on std APIs (`std.fs.cwd`, `ArrayList.init`, `std.io`, `GeneralPurposeAllocator`), the code was written against older Zig idioms — `native skills get zig` maps each such compile error to the 0.16 idiom as this SDK writes it.

For GUI smoke tests, build with automation enabled and use the `automation` skill:

```bash
zig build run -Dplatform=macos -Dautomation=true
zig-out/bin/native automate snapshot
```

When changing app behavior, keep tests in the app's existing authoring tier. TypeScript cores can run in the node dev loop and through generated full-loop tests; Zig-core logic uses focused Zig tests. Use automation-based tests for live window/runtime integration.

## Examples to inspect

- `examples/chatbot`: a substantial app authored entirely in TypeScript + Native markup, with streaming fetch effects and modules.
- `examples/soundboard-ts`: TypeScript + Native markup port of the full music-player showcase.
- `examples/system-monitor-ts`: TypeScript + Native markup app using spawn effects, timers, and tables.
- `examples/hello`: smallest lower-level inline HTML/WebView app.
- `examples/webview`: bridge and WebView runtime example.
- `examples/browser`: layered WebView/browser-style example.
- `examples/next`: Next.js with production assets.
- `examples/react`, `examples/svelte`, `examples/vue`: Vite frontend apps.
- `examples/ios`, `examples/android`: mobile host embedding examples.

## When answering users

Lead with the primary authoring story: applications are TypeScript cores plus Native markup by default, compiled to a small native binary with no JS runtime. Describe Zig as the toolkit implementation language and an explicit app-core/extension choice. Describe WebViews as a coexisting integration path for existing web content, not the starting point for a fresh app. If asked to implement, read the app files first, preserve the existing core language, and make the smallest change in the correct layer.
