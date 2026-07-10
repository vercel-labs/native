# Frontend and Assets

Use this when working with React, Vue, Svelte, Next.js, Vite, dev servers, HMR, static assets, or packaged frontend output.

## Recommended source pattern

Framework apps should use a dynamic source:

```zig
fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
    const self: *App = @ptrCast(@alignCast(context));
    return native_sdk.frontend.sourceFromEnv(self.env_map, .{
        .dist = "frontend/dist",
        .entry = "index.html",
    });
}
```

`sourceFromEnv` checks `NATIVE_SDK_FRONTEND_URL`. If set, the WebView loads the dev server URL. If not set, it serves packaged assets from `dist`.

## Manifest frontend config

```zig
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
```

Fields:

- `dist`: built frontend output path.
- `entry`: HTML entry file within `dist`.
- `spa_fallback`: serve `entry` for unknown routes.
- `dev.url`: local dev server URL.
- `dev.command`: command the Native SDK can spawn.
- `dev.ready_path`: path to poll for readiness.
- `dev.timeout_ms`: readiness timeout.

## Dev server workflow

Use:

```bash
zig build dev
```

Or directly:

```bash
native dev --manifest app.zon --binary zig-out/bin/MyApp
```

The dev command starts the frontend process, waits for readiness, sets `NATIVE_SDK_FRONTEND_URL`, launches the native shell, and terminates the frontend when the shell exits.

Framework defaults:

- Vite, React, Vue, Svelte: `http://127.0.0.1:5173/`, command `npm run dev -- --host 127.0.0.1`.
- Next.js: `http://127.0.0.1:3000/`, command `npm run dev -- --hostname 127.0.0.1`.

## Production assets

For packaged builds, serve local assets from `zero://app`:

```zig
return native_sdk.frontend.productionSource(.{
    .dist = "frontend/dist",
    .entry = "index.html",
});
```

The package/build flow should build the frontend before packaging. `zig build bundle-assets` and `native bundle-assets` copy the configured dist directory into build/package output.

## Security and frontend origins

Add exact origins to `security.navigation.allowed_origins`:

```zig
.security = .{
    .navigation = .{
        .allowed_origins = .{
            "zero://app",
            "http://127.0.0.1:5173",
        },
    },
},
```

Use `zero://inline` only for inline examples. Do not allow `"*"` for production navigation.

For packaged HTML, start with a strict CSP:

```html
<meta http-equiv="Content-Security-Policy"
  content="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'">
```

For dev servers, keep development CSP separate and add only the local dev/WebSocket endpoints required by the framework.

## Frontend to native calls

Use:

```javascript
const result = await window.zero.invoke("native.ping", { source: "webview" });
```

For builtin windows/WebViews helpers, enable `js_window_api` and policy in the runner. For custom commands, register handlers in Zig and allow the command in policy.

## Example projects

- `examples/next`: Next.js app with production assets under `frontend/out`.
- `examples/react`: React with Vite.
- `examples/solid`: Solid with Vite.
- `examples/svelte`: Svelte with Vite.
- `examples/vue`: Vue with Vite.

When unsure about frontend build commands or output directories, inspect the matching example before editing.
