# Native SDK system monitor example

A live CPU / memory / process monitor built to showcase the effects channel: a repeating `fx.startTimer` tick spawns the OS's own commands through `fx.spawn` (collect mode), `update` parses their stdout with pure fixture-tested parsers, and the UI derives everything from the model — stat tiles with 60-sample sparkline history, a top-CPU process table with search and sort toggles, and a context-menu SIGTERM action behind a real confirmation dialog. Zero third-party services; the "backend" is `ps`, `vm_stat`, and `sysctl`.

## The sampling loop (the showcase)

Every 2 seconds a repeating timer effect fires and `update` spawns two commands in `.collect` mode:

- `/bin/ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` — the shared process list. One invocation yields the top-CPU table rows, the exact process count, the summed %cpu (normalized by core count for the CPU tile — honest label: ps %cpu is a per-process decaying average, so this is a smooth load figure), and the uptime, read from pid 1's elapsed time (launchd/init started at boot, so its `etime` IS the uptime — no wall-clock math, no extra command).
- the per-OS memory command, switched at comptime: macOS parses `vm_stat` (used = active + wired + compressor pages) against a boot-time `sysctl hw.memsize` total; Linux parses `/proc/meminfo` (`MemTotal - MemAvailable`, totals included). Other OSes get no sampler and the status bar says so instead of pretending.

A tick that lands while the previous spawns are still running is **skipped and counted** (`ticks_skipped`, shown in the status bar) — overlapping two `ps` runs would only add the load this app measures. Boot also runs one host-info spawn (`sysctl -n hw.ncpu hw.memsize` / `nproc`) and an eager first sample so the window never sits empty for a full interval. Pause/resume cancels and re-arms the timer through the same message the toolbar chip presses.

## Sparklines

Each charted stat keeps 60 samples (a 2-minute window at the 2 s cadence), shifted in place. The charts are gpu-dashboard-style chart drawing built in Zig views: one thin token-tinted bar widget per sample, bottom-aligned in a fixed 239x32 box, entering from the right like a scope trace. Bars live in the retained widget tree, so they re-theme with the palette, respect layout budgets, and appear in automation snapshots like everything else. (The vector core's `strokePath` was the alternative; three 60-point polylines exceed the 128 path-elements-per-view budget, so bars are the honest fit — and read better at this size anyway.) CPU and memory bars scale against their absolute range; the process-count bars normalize against the window's own maximum, since counts have no natural ceiling.

## Terminating a process (safety, documented)

Right/ctrl-click a table row for the native context menu. **Terminate (SIGTERM)…** never signals directly: it opens a confirmation dialog naming the process and pid (copied into the model at request time, so a later sample can never retarget a confirmation you are reading). Confirming spawns exactly `/bin/kill -TERM <pid>` — the polite, catchable request. There is no SIGKILL anywhere in this app. A refused kill (not your process) lands as a status note, never a crash. The scrim cancels on click; the dialog body absorbs presses so a click inside it never falls through to the cancel.

## Authoring split (markup-first)

- `src/header.zml` — brand, live/paused status line, model-driven exclusive theme chips.
- `src/view.zig` — the Zig sections: stat tiles, sparkline bar charts, the toolbar (vector icons paired with press handlers — play/pause, x, chevrons; markup buttons carry text only), the process table with per-row context menus, and the modal confirmation overlaid through a z-stack root.
- `src/sampler.zig` — the pure parsers and per-OS command lines; no effects, no allocation.
- `src/model.zig` — sampling state, history, table derivations, `update`, `boot`.
- `src/theme.zig` — the teal/slate "ops room" token set for both modes; high-contrast falls back to the framework palettes.

## Fixtures (committed real output)

`src/fixtures/ps.txt`, `vm_stat.txt`, and `sysctl.txt` are a real capture from a macOS machine (10 cores, 32 GiB). The ps capture was reduced to its system rows (`/sbin`, `/usr`, `/bin`, `/System` — 561 of the original 644) so no user-account processes are committed; what remains is verbatim, including real spaces-in-path commands. `ps-edge.txt` is constructed (stated here, not passed off as a capture) to pin the edge cases a quiet capture cannot: day-form etimes, un-pathed names with spaces, a garbage line that must count as skipped. The Linux `/proc/meminfo` parser test uses a constructed sample in the documented shape for the same reason — no Linux capture machine here.

## Fixed capacities

- 60 history samples per charted stat; 2 s cadence.
- 128 top-CPU rows kept per sample (an exact top-K selection over the full ps output — never "the first 128 lines"; count and CPU sum still cover every process). 14 rows shown in the table.
- 48-byte process names (display cut, never dropped), 32-byte search buffer, 160-byte status note.
- 3 context-menu entries per row x 14 rows = 42 of the 128 per-view budget.
- Widget tree peaks around 320 nodes of the 1024 per-view budget (three 60-bar sparklines are the bulk).

## Run

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Watch the tiles fill in, filter the table, flip the sort chips, pause and resume sampling. Right-click a row you own (a `sleep 600 &` makes a safe target) and confirm the SIGTERM.

Run the deterministic suite (fixture parsers, the sampling loop through the fake effects executor with TestClock timestamps, the history ring, sort/search/kill through typed dispatch, theming, markup parity, snapshot assertions, and the exact-frame tile layout):

```sh
zig build test -Dplatform=null
```

The suite also carries an env-gated screenshot renderer (`SYSTEM_MONITOR_SHOTS=1`, skipped by default): it replays real `ps`/`vm_stat` captures through the normal update path and renders both themes OFFSCREEN through the deterministic reference renderer — no live window, no screen access, no macOS screen-recording permission. See the test's comment for the capture loop.

Verify live through the automation harness:

```sh
zig build -Dplatform=macos -Dweb-engine=system -Dautomation=true
./zig-out/bin/system-monitor &
native automate assert 'gpu_nonblank=true' 'role=button name="Pause or resume sampling"' 'name="CPU tile"'
native automate screenshot monitor-canvas
```
