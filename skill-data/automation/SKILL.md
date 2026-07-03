---
name: automation
description: Automation and verification guide for running zero-native WebView shell apps. Use when the user asks to test an app, inspect runtime state, list windows, wait for readiness, reload a WebView, send bridge commands, debug why automation is not connected, create smoke tests, or verify a zero-native example in a GUI-capable session.
---

# Automate zero-native apps

zero-native has a built-in automation system for inspecting running WebView shell apps. It works through file-based IPC in `.zig-cache/zero-native-automation/` and is intended for smoke tests, CI checks with a GUI session, and quick runtime inspection.

Automation is not browser DOM automation. It reports runtime/window/source state and can ask the runtime to reload or dispatch bridge requests. For frontend DOM testing, use the frontend framework's tests or a browser automation tool against the dev server.

## What automation can verify

- An automation-enabled app started and published `ready=true`.
- The runtime loaded the expected app name, source kind, and window metadata.
- The main window exists and is focused/open.
- The JavaScript-to-Zig bridge can round-trip a request through `zero-native automate bridge`.
- Builtin window/WebView commands work when exercised by a smoke test.
- Reload requests are accepted by the runtime.
- Real pixels of retained-canvas (`gpu_surface`) views: `zero-native automate screenshot <view-label>` renders the view's current canvas frame through the deterministic CPU reference renderer and writes a PNG artifact. Two captures of an unchanged scene are byte-identical, so screenshots can back golden-image or "did the UI change" checks.

## What automation cannot verify

- Screenshots of WebView content. `screenshot` covers `gpu_surface` canvas views only; there is no DOM/WebView pixel capture.
- Arbitrary DOM queries and clicks.
- Browser network assertions.

## Prerequisites

Build/run an app with automation enabled. Generated examples usually expose `-Dautomation=true`:

```bash
zig build run -Dplatform=macos -Dautomation=true
```

Repository examples may have specialized steps:

```bash
zig build run-webview -Dplatform=macos -Dautomation=true
zig build test-webview-smoke -Dplatform=macos
```

The runner must pass an automation server into `RuntimeOptions`:

```zig
const server = zero_native.automation.Server.init(io, ".zig-cache/zero-native-automation", "My App");
var runtime = zero_native.Runtime.init(.{
    .platform = my_platform,
    .automation = server,
});
```

Apps built without `-Dautomation=true` usually ignore automation files.

## Commands

```bash
zero-native automate wait
zero-native automate assert 'gpu_nonblank=true' 'role=button name="Reset"'
zero-native automate assert --absent 'error event='
zero-native automate list
zero-native automate snapshot
zero-native automate reload
zero-native automate screenshot inbox-canvas
zero-native automate screenshot inbox-canvas 2
zero-native automate widget-action canvas 2 press
zero-native automate widget-click canvas 3
zero-native automate widget-drag canvas 4 0.25 0.82
zero-native automate widget-wheel canvas 5 18
zero-native automate widget-key canvas tab
zero-native automate widget-key canvas cmd+c
zero-native automate bridge '{"id":"smoke","command":"native.ping","payload":{"source":"automation"}}'
```

If using the repository-built CLI:

```bash
zig-out/bin/zero-native automate wait
zig-out/bin/zero-native automate snapshot
```

## Snapshot assertions (`automate assert`)

Prefer `zero-native automate assert` over `snapshot | grep` chains: it polls, so no sleeps, and its failure output carries the evidence (each missing pattern plus the snapshot tail).

```bash
zero-native automate assert 'gpu_nonblank=true' 'role=button name="Reset"' 'count: 0'
zero-native automate assert --timeout-ms 10000 '4 open'
zero-native automate assert --absent 'error event=' 'dispatch_errors=[1-9]'
```

Semantics:

- Every argument is a regex that must match somewhere in `snapshot.txt`. The command polls (100ms interval) until all match, then exits 0.
- `--timeout-ms <n>` bounds the polling (default 30000). On timeout it prints `missing: <pattern>` for each unmatched pattern, the last 20 snapshot lines, and exits non-zero — CI-friendly, no wrapper script needed.
- `--absent` inverts the whole invocation: every pattern must NOT match (poll until gone). Mix presence and absence by running two invocations.
- Supported regex subset: literals, `.`, postfix `*` `+` `?`, line anchors `^`/`$`, classes `[a-z]`/`[^0-9]`, and `\d \w \s` (with uppercase negations). No groups or alternation — pass multiple patterns instead.
- Quote patterns in single quotes so the shell leaves `"`, `$`, and `\d` alone.

## Standard workflow

1. Start the app with automation enabled.
2. Run `zero-native automate wait` to block until `snapshot.txt` contains `ready=true`.
3. Run `zero-native automate assert '<pattern>' ...` for state checks, or `zero-native automate snapshot` to eyeball app/window/source metadata.
4. Run `zero-native automate list` to inspect window summaries.
5. Run `zero-native automate bridge '...'` for bridge round-trip checks.
6. Use `zero-native automate widget-action <view-label> <widget-id> <action> [value]` to exercise retained canvas widget actions. `set_text` routes through the SAME input path real typing uses (focus, select-all, then a text-input event), so a TEA app's `on_input` mirror receives the edits and model state stays consistent with the on-screen field — it is not a presentation-only write.
7. Use `zero-native automate widget-click <view-label> <widget-id>` to exercise pointer-style retained widget routing.
8. Use `zero-native automate widget-drag <view-label> <widget-id> <start-x-ratio> <end-x-ratio> [start-y-ratio end-y-ratio]` for continuous pointer controls.
9. Use `zero-native automate widget-wheel <view-label> <widget-id> <delta-y>` for retained widget scroll input.
10. Use `zero-native automate widget-key <view-label> <key> [text]` for focused retained widget keyboard input. The key accepts modifier chords — `cmd+a`, `cmd+c`, `cmd+v`, `cmd+x`, `ctrl+shift+arrowleft` (`cmd` sets the primary shortcut modifier on every platform) — so select-all/copy/cut/paste and shift-extended selection are drivable; after a copy, widget lines in the snapshot show the live selection as `selection=a..b`, and the copied text lands on the real system clipboard (`pbpaste` on macOS).
11. Use `zero-native automate screenshot <view-label> [scale]` to capture the named `gpu_surface` view's canvas as `screenshot-<view-label>.png` (the CLI prints the artifact path and waits for the file).
12. Use `zero-native automate reload` to request a WebView reload.

## Screenshots

`screenshot <view-label> [scale]` asks the runtime to rasterize the view's
current retained canvas frame through the deterministic CPU reference
renderer — the same pixel path the Linux software presentation uses — and
publish it as an uncompressed PNG at
`.zig-cache/zero-native-automation/screenshot-<view-label>.png`. The file is
written atomically (temp file + rename), so its presence means the PNG is
complete.

Determinism semantics:

- Screenshots render at scale 1 by default regardless of the display's
  backing scale, so an unchanged scene produces byte-identical PNGs from
  capture to capture on the same machine. Pass an explicit scale (for
  example `2`) for high-DPI pixel dimensions.
- Screenshots use the live retained scene, including live design tokens and
  platform text measurement (CoreText on macOS): the layout matches what is
  on screen. Glyphs are rasterized by the reference renderer's deterministic
  block rendering, not the platform's font rasterizer, so screenshots are a
  layout/structure/color signal rather than a font-rendering signal.
- Cross-machine byte-identity is only guaranteed where text metrics are
  deterministic (the null platform's estimator). On platforms with a native
  text measurement provider, text widths can differ between OS versions, so
  compare screenshots taken on the same machine or assert on properties
  (dimensions, changed/unchanged) rather than exact bytes across machines.
- OS-level captures (`screencapture -x` on macOS) are NOT a substitute: in a
  shell without Screen Recording permission they exit 0 and silently return
  wallpaper-only images with no app window in them. If you shell out for a
  real-pixel capture, verify the image is not blank/wallpaper before trusting
  it; `automate screenshot` plus a semantics snapshot is the reliable pair.

## Bridge smoke test pattern

The request must be JSON with an ID, command, and payload:

```bash
zero-native automate bridge '{"id":"smoke","command":"native.ping","payload":{"source":"automation"}}'
```

Automation sends the request with origin `zero://inline`. The app's bridge policy must allow that origin or the call will reject with `permission_denied`. For packaged asset origins, app code often allows `zero://app`; for automation smoke tests, add `zero://inline` only when the test needs it.

Expected response shape depends on the handler. A typical `native.ping` handler returns:

```json
{"id":"smoke","ok":true,"result":{"message":"pong","count":1}}
```

If the command fails, inspect the bridge error code:

- `unknown_command`: no handler registered or wrong command name.
- `permission_denied`: origin or permission policy blocked it.
- `handler_failed`: Zig handler returned an error or invalid JSON.
- `payload_too_large`: request exceeded bridge limits.

## File protocol

The default directory is `.zig-cache/zero-native-automation/`, resolved against the CLI's CURRENT WORKING DIRECTORY — run `zero-native automate` from the app project's directory (where the app was launched). The dir is created by the running app, never by the CLI: a command sent from the wrong cwd fails loudly (`error: no automation dir at <abs path>`) instead of queueing into a dir no app reads, and every queued command prints the absolute dir it wrote to — check that line when a command seems to do nothing.

Files:

- `snapshot.txt`: app name, readiness, source kind, source size, window metadata, accessibility summary. The `ready=true` line also carries `dispatch_errors=<total>` and `dropped_trace_records=<total>`, and recent degraded handler/update errors appear as `  error event=<tag> name=<ErrorName> timestamp_ns=...` lines — a handler error no longer exits the app, so grep these to notice one happened.
- `windows.txt`: window list.
- `command.txt`: command input written by CLI and consumed by runtime.
- `bridge-response.txt`: last bridge response.
- `screenshot-<view-label>.png`: deterministic reference-rendered PNG of a `gpu_surface` view, written by the `screenshot` command.

The runtime polls `command.txt`. After processing a command, it writes `done`.

## Debugging automation failures

If `zero-native automate wait` times out:

1. Confirm the app is still running.
2. Confirm it was built with `-Dautomation=true`.
3. Confirm the runner passes `automation` into `Runtime.init`.
4. Check `.zig-cache/zero-native-automation/snapshot.txt`.
5. Delete stale files in `.zig-cache/zero-native-automation/` and restart the app.
6. Run with more tracing, for example `zig build run -Dtrace=all`.

If `snapshot` says no app connected:

- The automation directory may not exist yet.
- The app may be running from a different working directory.
- The app may be built without automation.
- The app may not have reached runtime startup.

If bridge automation fails:

- Check command name spelling.
- Check app handler registration.
- Check bridge policy origins for `zero://inline`.
- Check runtime permissions.
- Check that the handler returns valid JSON.

## CI and smoke tests

Use automation for minimal integration confidence:

```bash
zig build test-webview-smoke -Dplatform=macos
```

A good smoke test:

1. Builds an example with `-Dautomation=true` and `-Djs-bridge=true`.
2. Starts the app in a GUI-capable session.
3. Waits for readiness.
4. Verifies snapshot metadata (`automate assert` with the patterns that matter).
5. Sends `native.ping`.
6. Exercises builtin windows/WebViews if the app enables them.
7. Fails on timeout or unexpected bridge response.

Apps scaffolded by `zero-native init` ship this as `.github/workflows/ci.yml`: a null-platform `zig build test` job plus a Linux Xvfb smoke job that launches the binary, runs `automate wait`, asserts on the snapshot with `automate assert`, and checks a non-empty `automate screenshot` artifact. Extend that file rather than writing grep chains by hand.

Do not use automation for exhaustive UI testing. It is a runtime and bridge smoke layer.

## Notes

- Automation is compile-time gated: apps built without `-Dautomation=true` ignore automation files.
- Screenshots cover retained-canvas (`gpu_surface`) views only; WebView pixels are not captured.
- WebView DOM interaction is intentionally out of scope for this file-based automation layer.
- Use `zero-native skills get core --full` for app architecture, bridge policy, packaging, and debugging context.
