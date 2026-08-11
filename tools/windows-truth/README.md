# windows-truth

The Windows live-truth loop: drives the toolkit's showcase apps on a real Windows 11 desktop over ssh, capturing what the OS actually does — window styles, min-size floors, input, clipboard, packaging — instead of trusting the null platform.

Prerequisites: the repo cloned at `%USERPROFILE%\repo` on the box, Zig 0.16 on PATH, the desktop logged in and UNLOCKED, and an ssh alias (key auth) whose default shell is cmd.exe. Anything that must touch the visible desktop hops through a `schtasks /IT` one-shot task; artifacts land in `%TEMP%\native-truth-out\`.

One command runs everything, or one named step:

```powershell
powershell -NoProfile -File tools\windows-truth\run-all.ps1 [recon|drive|perf|effects|record|writeback|package|all]
```

Steps: `recon.ps1` builds and launches every showcase app, dumping snapshots, widget inventories, and screenshots; `drive.ps1` replays per-app interaction scenarios (clicks, text input, wheel, resize); `perf-input.ps1` builds release `gpu-dashboard` and gates real OS hover latency plus sustained wheel frame cadence; `effects-run.ps1` probes spawn streaming, cancel, and clipboard; `record-replay.ps1` records a session and replays it headlessly with verification; `writeback-run.ps1` exercises markup write-back plus hot reload; `package-launch.ps1` launches and drives a packaged artifact. `window-probe.ps1` is the ad-hoc OS-window probe, and `lib.ps1` holds the shared helpers.

Run the performance gate by itself after building the repository CLI:

```powershell
powershell -NoProfile -File tools\windows-truth\perf-input.ps1
```

Its defaults require ten actual cursor-hover samples with built-in input-to-
present p90 below 20 ms and externally observed state p90 below 80 ms. The
two clocks must agree within the snapshot publisher's 60 ms p90 observation
budget. An automation-only command starts a harness-controlled retained
animation without changing the operator's reduce-motion preference. Its frame
count and interval budgets follow the HWND's active display refresh: on a
60 Hz desktop the defaults require at least 45 frames, 20 ms p90, and no gap
above 34 ms; an RDP desktop advertising (for example) 32 Hz is judged against
that real refresh and still fails if it runs below the available cadence.
The scroll phase attempts 120 modern `SendInput` wheel events over
roughly two seconds and requires Windows to deliver at least 80. Presented
frames may trail delivered inputs by at most two; the completion-gap budget
is 25 ms p90 with no gap above 50 ms. This delivered-input denominator keeps
OS input-stack coalescing from masquerading as an SDK frame drop. Results and
the final frame profile land in `%TEMP%\native-truth-out\perf-input\`.
