# zero-native gpu-dashboard example

This example combines native app chrome, a `gpu_surface`, and a retained canvas display list:

- Native toolbar, sidebar, and statusbar controls.
- A GPU surface registered with a dashboard display list.
- A WebView inspector sibling in the same split layout.
- Frame diagnostics for canvas command, batch, and resource planning.

Run with the macOS system backend:

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless canvas and scene tests:

```sh
zig build test -Dplatform=null
```
