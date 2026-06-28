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

## What automation cannot verify

- Real screenshots. Current `screenshot` support is a placeholder/unsupported depending on backend.
- Arbitrary DOM queries and clicks.
- Visual layout correctness.
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
zero-native automate list
zero-native automate snapshot
zero-native automate reload
zero-native automate widget-action canvas 2 press
zero-native automate bridge '{"id":"smoke","command":"native.ping","payload":{"source":"automation"}}'
```

If using the repository-built CLI:

```bash
zig-out/bin/zero-native automate wait
zig-out/bin/zero-native automate snapshot
```

## Standard workflow

1. Start the app with automation enabled.
2. Run `zero-native automate wait` to block until `snapshot.txt` contains `ready=true`.
3. Run `zero-native automate snapshot` to confirm app/window/source metadata.
4. Run `zero-native automate list` to inspect window summaries.
5. Run `zero-native automate bridge '...'` for bridge round-trip checks.
6. Use `zero-native automate widget-action <view-label> <widget-id> <action> [value]` to exercise retained canvas widget actions.
7. Use `zero-native automate reload` to request a WebView reload.

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

The default directory is `.zig-cache/zero-native-automation/`.

Files:

- `snapshot.txt`: app name, readiness, source kind, source size, window metadata, accessibility summary.
- `windows.txt`: window list.
- `command.txt`: command input written by CLI and consumed by runtime.
- `bridge-response.txt`: last bridge response.
- `screenshot.ppm`: placeholder screenshot artifact when supported by the runtime layer.

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
4. Verifies snapshot metadata.
5. Sends `native.ping`.
6. Exercises builtin windows/WebViews if the app enables them.
7. Fails on timeout or unexpected bridge response.

Do not use automation for exhaustive UI testing. It is a runtime and bridge smoke layer.

## Notes

- Automation is compile-time gated: apps built without `-Dautomation=true` ignore automation files.
- The current screenshot artifact is a placeholder PPM or unavailable depending on backend.
- WebView DOM interaction is intentionally out of scope for this file-based automation layer.
- Use `zero-native skills get core --full` for app architecture, bridge policy, packaging, and debugging context.
