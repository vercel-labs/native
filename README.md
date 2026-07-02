# zero-native

Build native desktop apps with Zig, secure WebView surfaces, native-rendered components, and OS capabilities. Tiny binaries. Minimal memory. Instant rebuilds.

zero-native is a native app framework where WebView content is one first-class surface, not the whole app model. Use native windows, menus, shortcuts, zero-native components, dialogs, and OS services around rich product UI. Use WebViews when a feature should stay web-shaped, such as browser surfaces, rich previews, embedded web apps, or third-party content.

## Quick Start

Install the CLI:

```bash
npm install -g zero-native
```

Create and run an app:

```bash
zero-native init my_app            # native-rendered app (default)
zero-native init my_app --frontend next   # or a WebView app with a web frontend
cd my_app
zig build run
```

The default app is native-rendered: a declarative `.zml` view plus Zig logic, with hot reload of the view while the app runs. With a web frontend selected, the first run installs frontend dependencies and opens a desktop window rendering your WebView content.

Read the full guide at [zero-native.dev/quick-start](https://zero-native.dev/quick-start).

## Why zero-native

### Native shell, web where it fits

Build app chrome and trusted utility surfaces with native views and zero-native components, while keeping WebViews available for browser-like workflows, rich previews, embedded web apps, and third-party content.

### Tiny and fast

System WebView apps do not bundle a browser runtime, so the native shell stays small and starts quickly. Your app uses WKWebView on macOS and WebKitGTK on Linux.

### Choose your web engine

Pick the engine that fits the product. System WebView gives you a lightweight native footprint. Chromium through CEF gives you predictable rendering and a pinned web platform on supported targets.

### Fast native rebuilds

The native layer is Zig, so app logic, bridge commands, and platform integrations rebuild quickly. Your frontend can still use the web tooling you already know.

### OS power without heavy glue

Zig calls C directly, which keeps platform SDKs, native libraries, codecs, and local system integrations within reach when the WebView layer needs to do real native work.

### Explicit security model

The WebView is treated as untrusted by default. Native commands, permissions, navigation, external links, and window APIs are opt-in and policy controlled.

## Status

zero-native is pre-release. Desktop support now covers macOS 11+, Linux, and Windows build paths, platform shell controls on system-WebView hosts, native-rendered canvas widgets, and Chromium/CEF distributed as platform-specific runtimes.

## Core Concepts

`App` is the small Zig object that describes your application: name, WebView source, lifecycle hooks, an optional native scene, and native services.

`Runtime` owns the event loop, windows, native views, WebViews, command routing, bridge dispatch, automation hooks, tracing, and platform services.

`ShellConfig` declares native-first windows and view trees: toolbars, sidebars, status bars, split panes, stacks, controls, WebViews, GPU surfaces, and future surface kinds.

`canvas.builtin_component_kinds` declares zero-native's built-in component catalog. The defaults follow shadcn's look and feel, use Geist and Geist Mono typography, and render through zero-native's retained canvas/GPU surface.

`WebViewSource` tells the runtime what a WebView should load: inline HTML, a URL, or packaged frontend assets served from a local app origin.

`app.zon` is the app manifest. It declares app metadata, icons, windows, native shell views, frontend assets, web engine selection, security policy, bridge permissions, and packaging inputs.

`window.zero.*` is the guarded JavaScript-to-native bridge for commands, windows, views, WebViews, dialogs, clipboard, credentials, and OS services. Calls are size-limited, origin checked, permission checked, and routed only to allowed handlers.

## Configuration

Most project-level behavior lives in `app.zon`:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .web_engine = "system",
    .permissions = .{},
    .capabilities = .{ "webview" },
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
- [Native Surfaces](https://zero-native.dev/native-surfaces)
- [Native Controls](https://zero-native.dev/native-controls)
- [Built-in Components](https://zero-native.dev/built-in-components)
- [Commands](https://zero-native.dev/commands)
- [Capabilities](https://zero-native.dev/capabilities)
- [Platform Support](https://zero-native.dev/platform-support)
- [Bridge](https://zero-native.dev/bridge)
- [Security](https://zero-native.dev/security)
- [Packaging](https://zero-native.dev/packaging)

## Examples

Framework-specific starter examples live in `examples/`:

- `examples/next`
- `examples/react`
- `examples/svelte`
- `examples/vue`

Each example is a complete zero-native app with `app.zon`, a Zig shell, and a minimal frontend project. Run one with `zig build run` from its directory.

Native-first examples are available too:

- `examples/command-app` - shared command routing across native controls, menus, shortcuts, tray, and bridge calls
- `examples/native-shell` - native toolbar/sidebar/statusbar chrome around WebView content
- `examples/native-panels` - split/stack native panel composition with WebView content
- `examples/gpu-surface` - Metal-backed GPU surface composed beside native controls and WebView content
- `examples/gpu-components` - shadcn-style built-in component lab rendered through the retained GPU canvas
- `examples/capabilities` - guarded OS services such as notifications, clipboard, dialogs, credentials, file drops, and recent documents
- `examples/mobile-shell` - shared metadata for the iOS and Android native shell hosts

Mobile embedding examples are available too:

- `examples/ios`
- `examples/android`

These show how an iOS or Android host app links the zero-native C ABI from `libzero-native.a`.

For local framework development, see [CONTRIBUTING.md](./CONTRIBUTING.md).
