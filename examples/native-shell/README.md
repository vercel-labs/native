# zero-native native-shell example

This example shows the native-first app shape:

- Native toolbar, sidebar, title accessory, and statusbar views.
- Main WebView used as the content workspace.
- One `app.refresh` command handled from the native menu, native button, command bridge, and app shortcut.
- Manifest command catalog listing from the WebView.
- `App.scene_fn` returning the native shell scene at startup.
- `.shell` metadata in `app.zon` that mirrors the runtime view structure.

Run with the system backend:

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless test path:

```sh
zig build test -Dplatform=null
```
