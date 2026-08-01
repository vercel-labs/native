# WebView Example

A Native SDK app with inline HTML, a native bridge command (`native.ping`), and builtin window management commands.

Use this example when you need to call Zig from JavaScript. The shape is:

1. Add a Zig handler with the `native_sdk.bridge.Invocation` signature.
2. Register it in a `BridgeDispatcher`.
3. Pass the dispatcher as `.bridge = app.bridge()` when starting the runner.
4. Call it from WebView JavaScript with `window.zero.invoke("native.ping", payload)`.

Inside the example app struct, the `native.ping` handler increments a Zig counter and returns JSON:

```zig
fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *@This() = @ptrCast(@alignCast(context));
    self.ping_count += 1;
    return std.fmt.bufPrint(output, "{{\"message\":\"pong from Zig\",\"count\":{d}}}", .{self.ping_count});
}
```

The WebView calls it like any other async JavaScript API:

```javascript
const result = await window.zero.invoke("native.ping", { source: "webview" });
```

The example also has a unit test that dispatches the same bridge message without launching a real WebView.

## Run

```bash
zig build run
```

With Chromium/CEF:

```bash
zig build run -Dweb-engine=chromium -Dcef-auto-install=true
```

With automation enabled (for testing):

```bash
zig build run -Dautomation=true
```

## Using outside the repo

This example references the Native SDK via relative path (`../../`). To use it standalone, override the path:

```bash
zig build run -Dnative-sdk-path=/path/to/native-sdk
```

Or, when a published Zig package is available, replace `default_native_sdk_path` in `build.zig` with the package URL and add it to `build.zig.zon` dependencies.
