# Commands

Commands are the shared routing layer for native app actions. Menus, shortcuts, toolbar controls, tray items, native controls, bridge calls, and runtime code can all dispatch the same command name into `Event.command`.

```zig
fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
    _ = context;
    switch (event_value) {
        .command => |command| {
            if (std.mem.eql(u8, command.name, "app.refresh")) {
                try runtime.updateView(command.window_id, "status", .{
                    .text = "Refreshed",
                });
            }
        },
        else => {},
    }
}
```

## Sources

`CommandEvent.source` identifies where the action came from:

<table>
  <thead>
    <tr>
      <th>Source</th>
      <th>Emitted by</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>.runtime</code></td>
      <td>Direct <code>runtime.dispatchCommand(...)</code> calls</td>
    </tr>
    <tr>
      <td><code>.menu</code></td>
      <td>Native menu items</td>
    </tr>
    <tr>
      <td><code>.shortcut</code></td>
      <td>Native keyboard shortcuts</td>
    </tr>
    <tr>
      <td><code>.toolbar</code></td>
      <td>Native controls inside a toolbar view</td>
    </tr>
    <tr>
      <td><code>.tray</code></td>
      <td>Tray actions</td>
    </tr>
    <tr>
      <td><code>.native_view</code></td>
      <td>Native controls outside toolbar views</td>
    </tr>
    <tr>
      <td><code>.bridge</code></td>
      <td><code>window.zero.commands.invoke(...)</code></td>
    </tr>
  </tbody>
</table>

Use `command.name` for the action and `command.source` only when the app genuinely needs source-specific behavior. Tray commands also include `tray_item_id` for apps that still need to distinguish legacy tray items that dispatch `"tray.action"`.

## Command names

Command names are stable IDs, not display labels. Use namespaced lowercase IDs:

```zig
const shortcuts = [_]native_sdk.Shortcut{
    .{ .id = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
};

const view_items = [_]native_sdk.MenuItem{
    .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
};
```

The same command can be bound to a menu item, shortcut, toolbar button, tray item, and bridge call. The runtime validates command IDs and rejects empty, oversized, or path-like names.

`app.zon` can also declare shared command metadata:

```zig
.commands = .{
    .{ .id = "app.refresh", .title = "Refresh" },
    .{ .id = "app.sidebar.toggle", .title = "Sidebar", .checked = true },
},
```

This metadata gives native and web entry points a common manifest-level command catalog while runtime dispatch still happens through `Event.command`.

Generated runners load that catalog into runtime options. Native code can read the active commands without reparsing the manifest:

```zig
var buffer: [32]native_sdk.Command = undefined;
const commands = runtime.listCommands(&buffer);
for (commands) |command| {
    if (command.enabled) {
        // Bind command.id to native controls or custom UI.
    }
}
```

## Bridge invocation

When `js_window_api` and the built-in bridge policy allow it, WebView content can dispatch the same command:

```js
await window.zero.commands.invoke("app.refresh");
```

The resulting event has `source = .bridge`, the calling native `window_id`, and the calling view label when the call came from a named child WebView.

WebView content can also read the manifest command catalog:

```js
const commands = await window.zero.commands.list();
```
