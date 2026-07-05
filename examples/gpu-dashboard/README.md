# Native SDK gpu-dashboard example

This example combines native app chrome, a `gpu_surface`, and a retained canvas display list:

- Native toolbar, sidebar, and statusbar controls.
- A GPU surface registered with explicit presentation settings and a dashboard display list.
- Retained widget semantics for dashboard lists, forms, data grids, popovers, and scrolling.
- A glass popover rendered with retained widget backdrop blur.
- A WebView inspector sibling in the same split layout.
- Frame diagnostics for canvas profile risk, work units, commands, batches, and dirty regions.

Run with the macOS system backend. The GPU dashboard defaults to `ReleaseFast`; pass `-Doptimize=Debug` only when debugging renderer internals.

```sh
native dev
```

Run the headless canvas and scene tests:

```sh
native test -Dplatform=null
```
