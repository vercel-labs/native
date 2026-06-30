# zero-native gpu-components example

This example is a retained GPU widget lab for trying the finished native-first component surface:

- Native toolbar, sidebar, statusbar, and GPU surface shell views.
- Buttons, icon buttons, text, icons, fields, checkbox, toggle, slider, progress, segmented control, lists, scroll views, popovers, menus, tooltips, and data grids.
- Retained widget semantics for focus, press, toggle, select, text editing, scrolling, and data-grid roles.
- Token-driven rounded corners, shadows, blur, typography, color, and scroll physics.

Run with the macOS system backend. The GPU component lab defaults to `ReleaseFast`; pass `-Doptimize=Debug` only when debugging renderer internals.

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless canvas and scene tests:

```sh
zig build test -Dplatform=null
```
