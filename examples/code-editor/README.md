# code-editor

A compact native code editor whose complete visual tree lives in [`src/code-editor.native`](src/code-editor.native): launch the window, choose **Open Folder…**, select a directory in the platform picker, then use the file tree on the left to edit syntax-highlighted source on the right.

```sh
native dev
```

## What it demonstrates

- **A `.native` view** — layout, bindings, conditional states, tree rows, splitter, and code surfaces are declarative markup. It is compiled at comptime for release builds and hot-reloaded in debug builds without replacing the Zig-owned model.
- **A custom titlebar** — the hidden-inset titlebar is a draggable `.native` row that keeps the opened folder name centered while respecting the macOS traffic-light inset.
- **A real platform folder dialog** — the `CodeEditorApp` wrapper presents `Runtime.showOpenDialog` with `allow_directories = true`. The wrapper is deliberately narrow: `UiApp` keeps raw `std.Io` and modal platform calls outside elm-style `update`.
- **Independent native windows** — **Cmd+N** creates another code-editor window with its own folder, tree, tabs, edits, and file effects. **Cmd+O** opens or replaces the folder in the focused window only. **Cmd+W** closes the active tab, or closes that window when it has no tabs. **Cmd+Shift+[** and **Cmd+Shift+]** cycle the focused window's tabs with wrapping.
- **A bounded filesystem tree** — the chosen directory is scanned through Zig 0.16's explicit `std.Io`. The scan caps at 128 entries and 12 levels, and shows but does not descend into `.git`, Zig cache/output directories, or `node_modules`; the status bar reports caps and unreadable subdirectories.
- **Typed tree interaction** — visible rows carry `treeitem` semantics, one-based logical levels, model-owned disclosure state, stable path keys, click previews, and selection-only Up/Down navigation. Left selects a leaf's parent folder; Enter mounts an in-place file/folder rename field; Cmd+Enter opens the tree selection in a permanent tab. The two-pane divider is model-owned too.
- **Desktop editor tabs** — single-click file previews stay italic and replaceable, while double-clicking either the tree row or the preview tab pins it. The active tab always shows its close button; inactive tabs reveal theirs on hover.
- **Async file reads** — selecting a file starts `fx.readFile`; stale results are ignored by key. Editable source caps at 384 KiB so the largest bounded tree and tabs still fit the view's retained-text budget; invalid UTF-8/NUL-bearing files get an explicit binary state, and failures stay in the window.
- **The native code surface** — `Ui.code` supplies five-digit line numbers, no-wrap horizontal scrolling, viewport-scaled syntax highlighting, and language selection derived from the file extension.

## Tests

`native test` (or root `zig build test-example-code-editor`) scans a real temporary directory, proves generated directories are not traversed, checks expansion visibility, records file requests through the fake effects executor, builds both view states, and checks compiled-markup parity with the debug interpreter.
