# Extensions

The `ModuleRegistry` provides a hook-based extension system for adding modular capabilities to the runtime.

## Module structure

Each module has an info block, a context pointer, and optional lifecycle hooks:

```zig
const MyModule = struct {
    data: u32 = 0,

    fn start(context: *anyopaque, runtime: native_sdk.extensions.RuntimeContext) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.data = 42;
    }

    fn command(context: *anyopaque, runtime: native_sdk.extensions.RuntimeContext, cmd: native_sdk.extensions.Command) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, cmd.name, "reset")) self.data = 0;
    }
};
```

## Registering modules

```zig
var my_module = MyModule{};
const caps = [_]native_sdk.extensions.Capability{.{ .kind = .native_module }};
const modules = [_]native_sdk.extensions.Module{.{
    .info = .{ .id = 1, .name = "my-module", .capabilities = &caps },
    .context = &my_module,
    .hooks = .{ .start_fn = MyModule.start, .command_fn = MyModule.command },
}};
const registry = native_sdk.extensions.ModuleRegistry{ .modules = &modules };

var runtime = native_sdk.Runtime.init(.{
    .platform = my_platform,
    .extensions = registry,
});
```

## Module fields

<table>
  <thead>
    <tr>
      <th>Field</th>
      <th>Type</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>info.id</code></td>
      <td><code>u64</code></td>
      <td>Unique numeric identifier (duplicates rejected at validation)</td>
    </tr>
    <tr>
      <td><code>info.name</code></td>
      <td><code>[]const u8</code></td>
      <td>Human-readable module name</td>
    </tr>
    <tr>
      <td><code>info.capabilities</code></td>
      <td><code>[]const Capability</code></td>
      <td>Capabilities this module provides</td>
    </tr>
    <tr>
      <td><code>context</code></td>
      <td><code>*anyopaque</code></td>
      <td>Opaque pointer to module state</td>
    </tr>
    <tr>
      <td><code>hooks.start_fn</code></td>
      <td>optional</td>
      <td>Called when the runtime starts</td>
    </tr>
    <tr>
      <td><code>hooks.stop_fn</code></td>
      <td>optional</td>
      <td>Called when the runtime stops (reverse registration order)</td>
    </tr>
    <tr>
      <td><code>hooks.command_fn</code></td>
      <td>optional</td>
      <td>Called when a command is dispatched to modules</td>
    </tr>
  </tbody>
</table>

## Registry methods

<table>
  <thead>
    <tr>
      <th>Method</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>validate()</code></td>
      <td>Check for duplicate module IDs</td>
    </tr>
    <tr>
      <td><code>startAll(runtime)</code></td>
      <td>Call <code>start_fn</code> on all modules</td>
    </tr>
    <tr>
      <td><code>stopAll(runtime)</code></td>
      <td>Call <code>stop_fn</code> on all modules (reverse order)</td>
    </tr>
    <tr>
      <td><code>dispatchCommand(runtime, command)</code></td>
      <td>Call <code>command_fn</code> on all modules</td>
    </tr>
    <tr>
      <td><code>hasCapability(kind)</code></td>
      <td>Check if any module provides a capability</td>
    </tr>
  </tbody>
</table>

## Capability kinds

<table>
  <thead>
    <tr>
      <th>Kind</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>native_module</code></td>
      <td>A native Zig module</td>
    </tr>
    <tr>
      <td><code>webview</code></td>
      <td>WebView rendering</td>
    </tr>
    <tr>
      <td><code>js_bridge</code></td>
      <td>JavaScript bridge</td>
    </tr>
    <tr>
      <td><code>filesystem</code></td>
      <td>File system access</td>
    </tr>
    <tr>
      <td><code>network</code></td>
      <td>Network access</td>
    </tr>
    <tr>
      <td><code>clipboard</code></td>
      <td>Clipboard access</td>
    </tr>
    <tr>
      <td><code>custom</code></td>
      <td>Custom capability (with a <code>name</code> field)</td>
    </tr>
  </tbody>
</table>

These map to the `capabilities` field in [app.zon](/docs/app-zon). The runtime can query whether any module provides a given capability using `registry.hasCapability(.filesystem)`.

## Native JS engine (experimental)

The `js` module provides an abstraction layer for calling into a native JavaScript engine from Zig. This is separate from the WebView bridge and is intended for future native module integrations.

<table>
  <thead>
    <tr>
      <th>Type</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>Value</code></td>
      <td>Tagged union: <code>null</code>, <code>boolean</code>, <code>number</code>, <code>string</code></td>
    </tr>
    <tr>
      <td><code>Call</code></td>
      <td>A function call: <code>module</code>, <code>function</code>, <code>args</code></td>
    </tr>
    <tr>
      <td><code>Bridge</code></td>
      <td>Validates and dispatches calls via <code>RuntimeHooks</code></td>
    </tr>
    <tr>
      <td><code>NullEngine</code></td>
      <td>Stub that returns <code>EngineUnavailable</code></td>
    </tr>
  </tbody>
</table>
