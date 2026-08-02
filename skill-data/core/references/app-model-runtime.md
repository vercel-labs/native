# App Model and Runtime

Use this when editing `src/main.zig`, `src/runner.zig`, lifecycle behavior, runtime setup, or tests.

## `App`

A Native SDK app returns a `native_sdk.App` value:

```zig
const App = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "my-app",
            .source = native_sdk.WebViewSource.html("<h1>Hello</h1>"),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }
};
```

Required fields:

- `context`: pointer to app state.
- `name`: app name for traces and automation snapshots.
- `source`: initial WebView source. Overridden by `source_fn` when present.

Optional callbacks:

- `source_fn`: dynamic source resolver.
- `start_fn`: called after runtime start and initial load.
- `event_fn`: receives lifecycle and runtime events.
- `stop_fn`: called before shutdown.

## `WebViewSource`

Choose one:

```zig
native_sdk.WebViewSource.html("<p>Inline</p>")
native_sdk.WebViewSource.url("http://127.0.0.1:5173/")
native_sdk.WebViewSource.assets(.{
    .root_path = "frontend/dist",
    .entry = "index.html",
    .origin = "zero://app",
    .spa_fallback = true,
})
```

Use inline HTML only for small examples and smoke tests. Use URL sources for explicit local/remote loading. Use assets for packaged apps.

## Runtime setup

Generated runners create a `Runtime` with platform services:

```zig
var runtime = native_sdk.Runtime.init(.{
    .platform = my_platform,
    .trace_sink = fanout.sink(),
    .bridge = my_app.bridge(),
    .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
    .security = .{
        .permissions = &app_permissions,
        .navigation = .{ .allowed_origins = &.{ "zero://app" } },
    },
    .js_window_api = true,
    .window_state_store = state_store,
    .automation = if (build_options.automation) automation_server else null,
});
try runtime.run(my_app.app());
```

`RuntimeOptions` fields agents commonly touch:

- `platform`: macOS, Linux, Windows, or `NullPlatform`.
- `trace_sink`: stdout/file/fanout trace destination.
- `bridge`: app-defined bridge dispatcher.
- `builtin_bridge`: policy for built-in windows, WebViews, and dialogs.
- `security`: permissions, navigation allowlist, external links.
- `automation`: file-based automation server.
- `window_state_store`: persisted window geometry.
- `js_window_api`: exposes `window.zero.windows` and `window.zero.webviews`.

## Windows from Zig

Use runtime methods for native window management:

```zig
const info = try runtime.createWindow(.{
    .label = "tools",
    .title = "Tools",
    .default_frame = native_sdk.geometry.RectF.init(80, 80, 420, 320),
});
try runtime.focusWindow(info.id);
```

Window limits:

- Max windows: 16.
- Max label bytes: 64.
- Max title bytes: 128.

Persisted window state is keyed primarily by `label`, so labels should be stable.

## EmbeddedApp

Use `EmbeddedApp` when another host owns the main loop:

```zig
var embedded = native_sdk.embed.EmbeddedApp.init(my_app.app(), my_platform);
defer embedded.deinit();
try embedded.start();
try embedded.frame();
try embedded.resize(new_surface);
try embedded.stop();
```

This is useful for mobile hosts, game engines, custom render loops, and headless tests. The repository includes iOS and Android examples that link `libnative-sdk.a` through Swift/Kotlin host apps.

`stop()` tells the app it is shutting down; `deinit()` releases what the embedded runtime owns on the heap (registered canvas font bytes). It is idempotent, so `defer embedded.deinit()` right after `init` is the idiom — an embedder that creates and destroys apps in one process leaks the font registry per cycle without it. The C ABI's `native_sdk_app_destroy` runs the same deinit through its host wrapper.

## Headless tests

Use `NullPlatform` or `TestHarness` when GUI behavior is not required:

```zig
var null_platform = native_sdk.NullPlatform.init(.{});
var runtime = native_sdk.Runtime.init(.{
    .platform = null_platform.platform(),
});
```

Good headless test targets:

- source selection
- bridge handler logic
- bridge policy enforcement
- lifecycle callbacks
- manifest/tooling behavior

Use automation smoke tests for real WebView/window integration.
