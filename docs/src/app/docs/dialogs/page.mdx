# Dialogs

The Native SDK provides native file and message dialogs accessible from Zig via `Runtime.showOpenDialog(...)`, `Runtime.showSaveDialog(...)`, and `Runtime.showMessageDialog(...)`, or from JavaScript via the [builtin bridge](/docs/bridge/builtin-commands).

## Open file dialog

<table>
  <thead>
    <tr>
      <th>Field</th>
      <th>Type</th>
      <th>Default</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>title</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>default_path</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>filters</code></td>
      <td><code>[]const FileFilter</code></td>
      <td><code>&.{}</code></td>
    </tr>
    <tr>
      <td><code>allow_directories</code></td>
      <td><code>bool</code></td>
      <td><code>false</code></td>
    </tr>
    <tr>
      <td><code>allow_multiple</code></td>
      <td><code>bool</code></td>
      <td><code>false</code></td>
    </tr>
  </tbody>
</table>

Returns `OpenDialogResult` with `count` and `paths`.

## Save file dialog

<table>
  <thead>
    <tr>
      <th>Field</th>
      <th>Type</th>
      <th>Default</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>title</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>default_path</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>default_name</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>filters</code></td>
      <td><code>[]const FileFilter</code></td>
      <td><code>&.{}</code></td>
    </tr>
  </tbody>
</table>

Returns an optional path string.

## Message dialog

<table>
  <thead>
    <tr>
      <th>Field</th>
      <th>Type</th>
      <th>Default</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>style</code></td>
      <td><code>MessageDialogStyle</code></td>
      <td><code>.info</code></td>
    </tr>
    <tr>
      <td><code>title</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>message</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>informative_text</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>primary_button</code></td>
      <td><code>[]const u8</code></td>
      <td><code>"OK"</code></td>
    </tr>
    <tr>
      <td><code>secondary_button</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
    <tr>
      <td><code>tertiary_button</code></td>
      <td><code>[]const u8</code></td>
      <td><code>""</code></td>
    </tr>
  </tbody>
</table>

**MessageDialogStyle**: `info`, `warning`, `critical`

**MessageDialogResult**: `primary`, `secondary`, `tertiary`

## FileFilter

```zig
const filters = [_]native_sdk.FileFilter{
    .{ .name = "Images", .extensions = &.{ "png", "jpg", "gif" } },
    .{ .name = "All Files", .extensions = &.{ "*" } },
};
```

## From JavaScript

Dialogs require the [builtin bridge](/docs/bridge/builtin-commands) to be enabled with an explicit policy that grants the `dialog` permission. JSON field names use camelCase:

```javascript
const files = await window.zero.invoke("native-sdk.dialog.openFile", {
  title: "Select a file",
  defaultPath: "/home",
  allowMultiple: true,
  allowDirectories: false,
});

const path = await window.zero.invoke("native-sdk.dialog.saveFile", {
  title: "Save as",
  defaultName: "untitled.txt",
});

const result = await window.zero.invoke("native-sdk.dialog.showMessage", {
  style: "warning",
  title: "Confirm",
  message: "Delete this item?",
  informativeText: "This action cannot be undone.",
  primaryButton: "Delete",
  secondaryButton: "Cancel",
});
```
