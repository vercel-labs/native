# Workspace Desk

A TypeScript and Native markup workspace with nested resizable panes.
The navigation and editor fractions belong to the model through `on-resize`;
Notes retains its divider position across refreshes. Review is disabled.

```sh
native dev
native test
native build -Dtypescript-view=true
native test -Dtypescript-view=true
```

Drag a divider, or focus it with Tab and use Left/Right, Shift+Left/Right,
and Home/End. Pane minimum widths bound every resize. Try the writing and
preview presets, reverse or hide previews, clear and restore them, lock the
layout, and mount a new workspace.

The compiled view preview requires rebuilding after markup edits.
