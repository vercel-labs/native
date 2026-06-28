# zero-native gpu-surface example

This example shows a real GPU-backed child surface in the native view tree:

- A native toolbar and statusbar.
- A Metal-backed `gpu_surface` pane.
- A WebView sibling pane in the same split layout.
- Native controls that dispatch commands back to Zig.

Run with the macOS system backend:

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless declaration test:

```sh
zig build test -Dplatform=null
```
