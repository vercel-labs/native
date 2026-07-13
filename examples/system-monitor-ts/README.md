# Native SDK system monitor example (TypeScript)

The live CPU / memory / process monitor authored entirely in **TypeScript + Native markup** — the spawn-showcase port of `examples/system-monitor`. Zero Zig: the logic tier is the app-core subset under `src/`, transpiled to native at build time as one module; `src/app.native` is the whole view tier and `app.zon` the manifest. The build detects `src/core.ts` in the tree and stages the wiring itself; no JS runtime ships in the binary.

The core is a multi-module reference split of the app-core subset's import-graph support:

- `src/core.ts` — the entry module: Model, Msg, update, subscriptions, the chromeMsg channel, and every exported binding helper (the app's public face — markup and node both see exactly its exports).
- `src/parsers.ts` — the pure byte parsers over the sampler tools' output (`ps`, `vm_stat`, `/proc/meminfo`, the probes), the integer number tier (`intDiv`), and the byte/format helpers.
- `src/table.ts` — the process table's search/sort/row-formatting machinery; type-imports `Model` from the entry (the legal back-edge shape).
- `@native-sdk/core/text` — the SDK's byte-splice text engine, transpiled in for the filter field's caret/selection/IME fidelity.

Everything the Zig monitor's core does is here: the 2 s sampling cadence as a declarative `Sub.timer` that exists exactly while sampling is live, collect-mode `Cmd.spawn` for the OS's own commands (`ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` shared across platforms, `vm_stat` or `/proc/meminfo` for memory, a boot host-info probe), pure byte parsers over the collected stdout (fixture-proven against the Zig example's committed real captures), skipped-tick accounting (a tick that lands mid-spawn is counted, never overlapped), the exact top-128-by-CPU row selection with the full count and CPU sum still covering every process, uptime from pid 1's elapsed time, 60-sample NaN-padded sparkline windows drawn by markup `<chart>` elements, the search/sort/filter table on the real table register with controlled scroll, the confirmed SIGTERM context-menu action (`/bin/kill -TERM <pid>` — no SIGKILL anywhere), Copy Name onto the clipboard, the journaled `Cmd.now` sample timestamp, the honest no-sampler empty state, and the tall hidden-inset titlebar header driven by the `chromeMsg` channel.

```sh
native dev                                    # run the real app
native dev --core --script dev-script.ndjson  # the core-logic loop under node - no renderer
native check                                  # subset-check the core's import graph + markup + app.zon
native test -Dplatform=null                   # the hermetic suite
```

The end-to-end proof battery lives in the SDK repo (`tests/ts-core/system_monitor_e2e_tests.zig`, run by `zig build test-ts-core-e2e`): it drives this example's real core and shipping markup headlessly through the boot probe, scripted sampler outputs (the Zig example's committed `ps`/`vm_stat`/`sysctl` captures and its constructed edge fixture), the timer cadence with pause/resume, search, sorting, the kill round trip, the no-sampler state, and record→replay.

## The wiring channels this port uses

- **`chromeMsg`** — the tall hidden-inset titlebar geometry lands in the model: the header row leads with a spacer sized to the traffic lights and matches its height to the band, exactly like the Zig original's `on_chrome`.
- **`Sub.timer`** — the sampling cadence is declarative: `subscriptions(model)` returns the 2 s timer while the probe has answered and sampling is live; pause reconciles it away, resume re-arms it (and samples eagerly on the same dispatch).
- **`Cmd.spawn` (collect mode)** — every sampler run delivers its whole stdout on the exit arm; a truncated block routes the err arm and never parses as whole.
- **`Cmd.now`** — the applied sample's wall-clock stamp is a journaled clock read, so recorded sessions replay the same "sampled at" time.

## Where this port still deliberately differs from the Zig system-monitor

Every remaining divergence is a decided posture, listed here on purpose:

- **The OS is probed at runtime, not switched at comptime.** A TS core has no comptime OS, so boot spawns `sysctl -n hw.ncpu hw.memsize`; a clean answer means macOS conventions (vm_stat), falling through to `nproc` means Linux (/proc/meminfo), and both failing is the honest "no sampler for this OS" state — the same empty state, discovered instead of compiled in. The probe also carries the host facts the Zig original fetched in its boot spawn.
- **No settings window.** Model-declared secondary windows are a `windows_fn` (Zig wiring) channel; the three-file TS app has no wiring tier to declare one. Pause/resume — the settings window's one control — stays on the toolbar, and the `monitor.settings` shortcut is not registered.
- **Theme comes from app.zon, not a tokens_fn.** The Zig original derives a custom teal/slate "ops room" token set; a TS app owns no tokens_fn, so this port keeps the house register (composed with the live system appearance — light/dark still follows the OS with no core code). Full brand-token fidelity is the register-token tier, out of the three-file shape by design.
- **CPU numbers live in tenths of a percent, as integers.** The number tier splits integer and float domains, so `%cpu` parses to integer tenths (lossless for ps output, which prints one decimal) and the tile derives its display and sparkline fraction from them. A hypothetical tool printing more decimals would round at the second decimal where the Zig f32 parse would keep it; sort order can tie where sub-tenth values would have ordered.
- **Display rounding is round-half-up.** `formatBytes` and the percent labels round with integer math; Zig's `{d:.1}`/`{d:.0}` can differ in the last digit on exact halfway ties, which the real samplers do not produce.
- **A truncated ps block drops the sample whole.** The Zig original parses the first 512 KiB and counts one failure; collect-mode spawn routes `truncated` through the err arm with no payload, so this port notes the failure and keeps the previous sample — a cut block never parses as whole.
- **The sample timestamp lands one dispatch later.** `fx.wallMs` is a same-dispatch journaled read; the TS analogue is a `Cmd.now` round trip after the sample commits. Same journal, same replay determinism, one extra Msg.
- **Copy Name is fire-and-forget.** `Cmd.clipboardWrite` has no result routing, so the status note reports the request; the Zig original notes the confirmed outcome.
- **Row presses are absorbed by a no-op arm.** Markup context menus need a pressable host, so each table row binds `on-press="row_pressed"`; the Zig builder's `data_row` is its own hit target and needs none.
- **The kill confirmation's scrim is the `scrim` token.** The Zig original's cancel catcher is a fully transparent panel under the dialog chrome's scrim; markup panels take token backgrounds, so the catcher wears the scrim wash itself (the `notes` example's shipped overlay idiom).
- **Fragment hot reload covers the whole view.** The Zig original registers four compiled fragments; here `src/app.native` is the entire view tier and `native dev` hot-reloads it as one document.
- **Desktop only.** TypeScript cores build desktop apps today; there was no phone shell to port.
