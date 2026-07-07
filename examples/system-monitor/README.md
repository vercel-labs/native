# Native SDK system monitor example

A live CPU / memory / process monitor built to showcase the effects channel: a repeating `fx.startTimer` tick spawns the OS's own commands through `fx.spawn` (collect mode), `update` parses their stdout with pure fixture-tested parsers, and the UI derives everything from the model — stat tiles with 60-sample `ui.chart` sparklines, a top-CPU process table with search and sort toggles, and a context-menu SIGTERM action behind a real confirmation dialog. Zero third-party services; the "backend" is `ps`, `vm_stat`, and `sysctl`.

## The sampling loop (the showcase)

Every 2 seconds a repeating timer effect fires and `update` spawns two commands in `.collect` mode:

- `/bin/ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` — the shared process list. One invocation yields the top-CPU table rows, the exact process count, the summed %cpu (normalized by core count for the CPU tile — honest label: ps %cpu is a per-process decaying average, so this is a smooth load figure), and the uptime, read from pid 1's elapsed time (launchd/init started at boot, so its `etime` IS the uptime — no wall-clock math, no extra command).
- the per-OS memory command, switched at comptime: macOS parses `vm_stat` (used = active + wired + compressor pages) against a boot-time `sysctl hw.memsize` total; Linux parses `/proc/meminfo` (`MemTotal - MemAvailable`, totals included). Other OSes get no sampler and the status bar says so instead of pretending.

A tick that lands while the previous spawns are still running is **skipped and counted** (`ticks_skipped`, shown in the status bar) — overlapping two `ps` runs would only add the load this app measures. Boot also runs one host-info spawn (`sysctl -n hw.ncpu hw.memsize` / `nproc`) and an eager first sample so the window never sits empty for a full interval. Pause/resume cancels and re-arms the timer through the same message the toolbar chip presses.

## Sparklines

Each charted stat keeps 60 samples (a 2-minute window at the 2 s cadence), shifted in place. The charts are markup `<chart>` elements (`src/spark_*.native`, one compiled fragment per tile) lowered through the chart primitive — series drawn through the vector path pipeline with token colors, so they re-theme with the palette, invalidate on data changes, and report series semantics in automation snapshots. CPU and memory draw zero-baseline **bars** pinned to the absolute 0..1 domain (`y-min="0" y-max="1"`); the process count draws a filled **area** against the chart's auto domain (the window's own min..max), since counts have no natural ceiling and an absolute scale would render a featureless block. The series bind model fns (`cpuSpark`/`memSpark`/`procSpark`) that pad short histories with leading NaN — missing samples draw nothing — so the trace enters from the right like a scope. (This app originally hand-built the sparklines as sixty bar widgets per tile because three 60-point polylines blew the old 128 path-elements-per-view budget; the chart primitive plus the 2048 budget retired that idiom, and the markup chart element then retired the Zig sparkline view.)

## Terminating a process (safety, documented)

Right/ctrl-click a table row for the native context menu. **Terminate (SIGTERM)…** never signals directly: it opens a confirmation dialog naming the process and pid (copied into the model at request time, so a later sample can never retarget a confirmation you are reading). Confirming spawns exactly `/bin/kill -TERM <pid>` — the polite, catchable request. There is no SIGKILL anywhere in this app. A refused kill (not your process) lands as a status note, never a crash. The scrim cancels on click; the dialog body absorbs presses so a click inside it never falls through to the cancel.

## The settings window (model-declared)

**Settings** opens the standard way — the app menu's Settings item or its keyboard shortcut (primary+comma, registered in `app.zon` under `.shortcuts` and mapped to `.open_settings` in `main.zig`'s `command`) — in its own fixed-size window; there is no in-window settings button. It is the model-declared window pattern: `windows_fn` declares the window descriptor while `model.settings_open` is set, `window_view` renders `settingsView` (one grouped form row: the sampling switch with its cadence facts) from the same model as the main canvas, so flipping the switch updates both windows on one dispatch — live, no Apply step — and a system appearance change rethemes both canvases through `on_appearance`. Close it with the window's close button — the platform close dispatches `.settings_closed` and the model clears its flag. Automation drives it like any canvas: `native automate shortcut monitor.settings` opens it through the real command path, its widgets are in the snapshot, and `widget-click settings-canvas <id>` works while it is open.

## Authoring split (markup-first)

- `src/header.native` — brand and the live/paused status line holding the trailing corner (the status line itself is an imported component, `src/header_status.native`). The app follows the system appearance; there is no in-window theme control. All four markup fragments — the header and the sparklines — are registered with the runtime's fragment watch in `main.zig`, so a Debug `native dev` run hot reloads any of them (or the imported status component) on save.
- `src/spark_cpu.native`, `src/spark_mem.native`, `src/spark_proc.native` — the three sparkline charts, one `<chart>` fragment per stat tile, built into the Zig tile chrome as ordinary children.
- `src/view.zig` — the Zig sections: stat tiles, the toolbar (every control on the `.sm` register so the row renders one height — pause/resume button with its inline play/pause icon, filter field with the search component's own built-in clear affordance, sort toggles), the process table as flat `list_item` rows under a hairline-separated heading (one surface, full-width hover washes, per-row context menus) with a controlled scroll (the model echoes the applied offset, so the 2 s sample rebuild never resets it mid-gesture), and the modal confirmation overlaid through a z-stack root.
- `src/sampler.zig` — the pure parsers and per-OS command lines; no effects, no allocation.
- `src/model.zig` — sampling state, history, table derivations, `update`, `boot`.
- `src/theme.zig` — the teal/slate "ops room" token set for both modes, derived live from the system appearance; high-contrast falls back to the framework palettes.

## Fixtures (committed real output)

`src/fixtures/ps.txt`, `vm_stat.txt`, and `sysctl.txt` are a real capture from a macOS machine (10 cores, 32 GiB). The ps capture was reduced to its system rows (`/sbin`, `/usr`, `/bin`, `/System` — 561 of the original 644) so no user-account processes are committed; what remains is verbatim, including real spaces-in-path commands. `ps-edge.txt` is constructed (stated here, not passed off as a capture) to pin the edge cases a quiet capture cannot: day-form etimes, un-pathed names with spaces, a garbage line that must count as skipped. The Linux `/proc/meminfo` parser test uses a constructed sample in the documented shape for the same reason — no Linux capture machine here.

## Fixed capacities

- 60 history samples per charted stat; 2 s cadence.
- 128 top-CPU rows kept per sample (an exact top-K selection over the full ps output — never "the first 128 lines"; count and CPU sum still cover every process). 14 rows shown in the table.
- 48-byte process names (display cut, never dropped), 32-byte search buffer, 160-byte status note.
- 3 context-menu entries per row x 14 rows = 42 of the 128 per-view budget.
- Widget tree peaks around 140 nodes of the 1024 per-view budget (the chart retrofit collapsed three 60-bar sparklines into 3 leaves).

## Run

```sh
native dev
```

Watch the tiles fill in, filter the table, flip the sort chips, pause and resume sampling. Right-click a row you own (a `sleep 600 &` makes a safe target) and confirm the SIGTERM.

Run the deterministic suite (fixture parsers, the sampling loop through the fake effects executor with TestClock timestamps, the history ring, sort/search/kill through typed dispatch, theming, markup parity, snapshot assertions, and the exact-frame tile layout):

```sh
native test -Dplatform=null
```

The suite also carries an env-gated screenshot renderer (`SYSTEM_MONITOR_SHOTS=1`, skipped by default): it replays real `ps`/`vm_stat` captures through the normal update path and renders both themes OFFSCREEN through the deterministic reference renderer — no live window, no screen access, no macOS screen-recording permission. See the test's comment for the capture loop.

Verify live through the automation harness:

```sh
native build -Dautomation=true
./zig-out/bin/system-monitor &
native automate assert 'gpu_nonblank=true' 'role=button name="Pause or resume sampling"' 'name="CPU tile"'
native automate screenshot monitor-canvas
```
