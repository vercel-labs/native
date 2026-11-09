# GPU Dashboard

A TypeScript app core and Native markup view own the complete dashboard model, controls, appearance, chrome, retained animations, and frame-status text. scriptc compiles the core and view; the native host supplies AppKit, Metal, retained identities, presentation clocks, and resource lifetime.

The view includes navigation and metric lists, a data grid, forms, a blurred popover, a menu surface, and scrolling. `canvasChrome`, `canvasAnimations`, and `canvasFrameMsg` declare canvas behavior from model state. Appearance observations remain in the model so replay preserves contrast and reduced motion.

```sh
native dev
native test -Dplatform=null
```

From the SDK repository, run the complete independent native-reference comparison:

```sh
zig build test-ts-gpu-dashboard-e2e
zig build test-ts-canvas-hooks
```
