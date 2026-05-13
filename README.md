# zero-native

Build native desktop apps with web UI. Tiny binaries. Minimal memory. Instant rebuilds.

zero-native is a Zig desktop app shell for modern web frontends. Use the platform WebView when you want the smallest possible app, or bundle Chromium through CEF when rendering consistency matters.

## Quick Start

Install the CLI:

```bash
npm install -g zero-native
```

Create and run an app:

```bash
zero-native init my_app --frontend next
cd my_app
zig build run
```

The first run installs frontend dependencies, builds the generated native shell, and opens a desktop window rendering your web UI.

Read the full guide at [zero-native.dev/quick-start](https://zero-native.dev/quick-start).

## Why zero-native

### Tiny and fast

System WebView apps do not bundle a browser runtime, so the native shell stays small and starts quickly. Your app uses WKWebView on macOS and WebKitGTK on Linux.

### Choose your web engine

Pick the engine that fits the product. System WebView gives you a lightweight native footprint. Chromium through CEF gives you predictable rendering and a pinned web platform on supported targets.

### Fast native rebuilds

The native layer is Zig, so app logic, bridge commands, and platform integrations rebuild quickly. Your frontend can still use the web tooling you already know.

### Native power without heavy glue

Zig calls C directly, which keeps platform SDKs, native libraries, codecs, and local system integrations within reach when the WebView layer needs to do real native work.

### Explicit security model

The WebView is treated as untrusted by default. Native commands, permissions, navigation, external links, and window APIs are opt-in and policy controlled.

## Status

zero-native is pre-release. Desktop support now covers macOS 11+, Linux, and Windows build paths, with Chromium/CEF distributed as platform-specific runtimes.

## Core Concepts

`App` is the small Zig object that describes your application: name, WebView source, lifecycle hooks, and optional native services.

`Runtime` owns the event loop, windows, bridge dispatch, automation hooks, tracing, and platform services.

`WebViewSource` tells the runtime what to load: inline HTML, a URL, or packaged frontend assets served from a local app origin.

`app.zon` is the app manifest. It declares app metadata, icons, windows, frontend assets, web engine selection, security policy, bridge permissions, and packaging inputs.

`window.zero.invoke()` is the JavaScript-to-Zig bridge. Calls are size-limited, origin checked, permission checked, and routed only to registered handlers.

## Configuration

Most project-level behavior lives in `app.zon`:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .web_engine = "system",
    .permissions = .{ "window" },
    .capabilities = .{ "webview", "js_bridge" },
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
        },
    },
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640 },
    },
}
```

Use `.web_engine = "system"` for the platform WebView. On supported macOS builds, use `.web_engine = "chromium"` with a `.cef` config when you want to bundle Chromium.

## Documentation

The full documentation is at [zero-native.dev](https://zero-native.dev).

- [Quick Start](https://zero-native.dev/quick-start)
- [Web Engines](https://zero-native.dev/web-engines)
- [App Model](https://zero-native.dev/app-model)
- [Bridge](https://zero-native.dev/bridge)
- [Security](https://zero-native.dev/security)
- [Packaging](https://zero-native.dev/packaging)

## Examples

Framework-specific starter examples live in `examples/`:

- `examples/next`
- `examples/react`
- `examples/svelte`
- `examples/vue`
- `examples/angular`

Each example is a complete zero-native app with `app.zon`, a Zig shell, and a minimal frontend project. Run one with `zig build run` from its directory.

Mobile embedding examples are available too:

- `examples/ios`
- `examples/android`

These show how an iOS or Android host app links the zero-native C ABI from `libzero-native.a`.

For local framework development, see [CONTRIBUTING.md](./CONTRIBUTING.md).
