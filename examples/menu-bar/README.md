# Native SDK Menu Bar (TypeScript)

This app is the complete hide-to-tray lifecycle in the default TypeScript + Native markup tier:

- `app.zon` gives the main window `close_policy = "hide"`, so closing it leaves the process and status item alive.
- `src/core.ts` exports `statusItem(model)`, whose presentation and menu update from committed playback state.
- Tray commands pass through `commandMsg`; Open uses `Cmd.showWindow("main")`, and Quit uses `Cmd.quitApp()` for graceful termination.
- `src/app.native` is the ordinary player window. No app-owned Zig glue is involved.

```sh
native dev
native check
native test -Dplatform=null
```
