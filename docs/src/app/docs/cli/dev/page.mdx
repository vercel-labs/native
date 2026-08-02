# Dev Server

Run `native dev` in an app directory to build and launch the app. It builds Debug by default — the markup hot-reload watcher and the Debug-only teaching diagnostics are compiled in only in Debug; pass `-Doptimize=...` to override (`native build` stays ReleaseFast by default). Native-rendered apps get markup hot reload (edit `src/app.native` while the app runs); no build files are required — apps without a `build.zig` are driven through a CLI-generated build graph, apps with one through `zig build`.

For apps with a frontend dev config in `app.zon`, `native dev` also owns the frontend server lifecycle. It starts the configured frontend process, waits for the port to accept connections, launches the native shell with `NATIVE_SDK_FRONTEND_URL`, sets `NATIVE_SDK_HMR=1`, and terminates the frontend when the shell exits. Framework HMR stays owned by the dev server (Vite, Next.js, etc.) because the WebView loads the dev URL directly.

## Usage

```bash
native dev
native dev path/to/app -Dweb-engine=chromium
native dev --binary zig-out/bin/MyApp
native dev --binary zig-out/bin/MyApp --url http://127.0.0.1:3000/ --command "npm run dev"
native dev --binary zig-out/bin/MyApp --timeout-ms 60000
```

With `--binary`, the build step is skipped and only the frontend dev flow runs against the prebuilt shell (this is what the expanded template's `zig build dev` step invokes).

## Flags

<table>
  <thead>
    <tr>
      <th>Flag</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>--manifest</code></td>
      <td>Path to <code>app.zon</code> (default: <code>app.zon</code>)</td>
    </tr>
    <tr>
      <td><code>--binary</code></td>
      <td>Path to the built native binary</td>
    </tr>
    <tr>
      <td><code>--url</code></td>
      <td>Override dev server URL from <code>app.zon</code></td>
    </tr>
    <tr>
      <td><code>--command</code></td>
      <td>Override dev server command from <code>app.zon</code></td>
    </tr>
    <tr>
      <td><code>--timeout-ms</code></td>
      <td>Override readiness timeout (default from <code>app.zon</code>)</td>
    </tr>
  </tbody>
</table>

## Configuration in app.zon

```zig
.frontend = .{
    .dist = "dist",
    .entry = "index.html",
    .spa_fallback = true,
    .dev = .{
        .url = "http://127.0.0.1:5173/",
        .command = .{ "npm", "run", "dev", "--", "--host", "127.0.0.1" },
        .ready_path = "/",
        .timeout_ms = 30000,
    },
}
```

## Framework recipes

**Vite**: `.url = "http://127.0.0.1:5173/"`, command `npm run dev -- --host 127.0.0.1`.

**Next.js**: `.url = "http://127.0.0.1:3000/"`, command `npm run dev -- --hostname 127.0.0.1`.

**Static preview**: point `.dist` at the build output and use any local server command.
