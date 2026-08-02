# workbench

A live terminal beside a browser in one resizable split — the shape of a developer's second window, in about 250 lines of app code and 35 lines of markup.

The headline is what this app does NOT contain: no emulator wiring. The left pane is a single `<terminal pty={shell_key}>` element, and the runtime owns the session behind that key — feeding the pty's output into the emulator, routing focused keys and IME text back out through `ptyWrite`, driving `ptyResize` from the element's laid-out extent, and scrolling history on the wheel. This app spawns the shell (`fx.ptySpawn` in `init_fx`, naming the key the markup binds) and echoes the reported scrollback. That is the whole terminal.

The right pane is the browser: back, forward, reload, and an address bar in one compact toolbar, then the page. There are no tabs. The webview is a real embedded engine view snapped to the markup's anchor column every presented frame, so dragging the divider reflows live web content. Navigation history is APP-owned — the model holds the committed entries and the index, and the pane's URL derives from them, because a browser's history belongs to the app, not to the view.

```sh
zig build run                    # run the workbench
zig build test -Dplatform=null   # the markup shape, the history, the live session
```

## What to try

- Type in the terminal — a real interactive shell, with scrollback on the wheel.
- Drag the divider: the terminal re-grids (the pty is resized to the new cols/rows — `stty size` reports the new geometry) and the web page reflows in the same frame. The divider is a focusable control, so the drag leaves the keyboard on it; click the terminal to hand the shell the keyboard again.
- Enter an address (a bare host gets `https://`), then walk it with back and forward; the buttons disable at the ends of history.

## How it fits together

- `src/workbench.native` — the whole layout: one `<split>` with the terminal pane and the browser pane. The split fraction is model-owned (`value` + `on-resize`), so drags land in the model and the next build lays the panes exactly there.
- `src/main.zig` — the model (split fraction, scrollback echo, address buffer, history table), `boot`'s shell spawn, and the `web_panes` hook that gives the webview its URL and reload token.
- `build.zig` — the one reason this example owns its build: `terminal_sessions = true` opts into the emulator, resolving the lazy `ghostty` pin in this app's own `build.zig.zon`. Apps that do not ask for live sessions never traverse that dependency graph.

The chrome is the terminal-window look: a hidden-inset titlebar with no toolbar and no status bar, and a bare drag band at the top of each pane sized from the reported chrome insets, so only the traffic lights float over the terminal's own background.

Recorded sessions replay: the emulator is fed from the journaled pty output and every outbound byte goes through the journaled write path, so a replay reproduces the same screen with no shell present.
