# Native SDK gpu-surface example

This example shows a real GPU-backed child surface in the native view tree:

- A native toolbar and statusbar.
- A Metal-backed `gpu_surface` pane with explicit pixel format, presentation, alpha, color-space, and vsync settings.
- A WebView sibling pane in the same split layout.
- Native controls that dispatch commands back to Zig.

Run with the macOS system backend. The GPU surface example defaults to `ReleaseFast`; pass `-Doptimize=Debug` only when debugging renderer internals.

```sh
native dev
```

Run the headless declaration test:

```sh
native test -Dplatform=null
```
