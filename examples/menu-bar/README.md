# Native SDK Menu Bar (TypeScript)

This app is the complete hide-to-tray lifecycle in the default TypeScript + Native markup tier:

- `app.zon` sets `dock_visible = false`, so macOS selects Accessory before creating a window and no Dock tile flashes.
- The main window starts with `initially_hidden = true` and uses `close_policy = "hide"`; the status item is the only open/re-show affordance.
- `src/core.ts` exports `statusItem(model)`, whose presentation and menu update from committed playback state.
- Tray commands pass through `commandMsg`; Open uses `Cmd.showWindow("main")`, and Quit uses `Cmd.quitApp()` for graceful termination.
- Playback changes issue `Cmd.persist()`, so the engine restores the last playing/track state from its atomic app-data snapshot on the next launch.
- `src/app.native` is the ordinary player window. No app-owned Zig glue is involved.

```sh
native dev
native check
native test -Dplatform=null
```
