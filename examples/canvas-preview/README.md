# canvas-preview

The "native, web, or both per window" proof: one window hosting a Native SDK canvas (Metal-backed toolbar + sidebar rendered by the widget engine) and a live platform webview side by side. Its TypeScript core owns page selection, reload state, presented-frame state, pane declarations, and tray commands; `app.native` owns the canvas layout.

- The webview is an ordinary scene shell view (`kind = .webview`, parented to the canvas view). The build's web engine backs it: WKWebView with `-Dweb-engine=system` (default), bundled Chromium with `-Dweb-engine=cef` — the pane seam below is engine-agnostic, though gpu_surface canvases currently require the system engine on macOS.
- `webPanes(model): readonly WebViewPane[]` keeps the webview snapped to a canvas widget's layout frame — the empty panel carrying the `preview-pane` semantics label — through install, rebuilds, and resizes.
- The model owns `url` + `reloadToken` (the CenterPane/Preview-tab consumer shape): switching pages navigates, bumping the token reloads.
- `statusItem(model)` installs a menu-bar extra (macOS `NSStatusItem`) whose menu items dispatch the same `commandMsg` commands as the toolbar buttons.

Run it:

```sh
native dev
```

Automation smoke (from the repo root):

```sh
zig build test-canvas-preview-smoke
```

Headless tests:

```sh
native test
```

Compare the scriptc-compiled view with the native markup backend:

```sh
native test -Dtypescript-view=true
```
