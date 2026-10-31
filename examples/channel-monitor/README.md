# Channel Monitor

A TypeScript + Native markup app demonstrating a native external producer. Start opens a channel with `Cmd.channelOpenSource` and requests the explicit `native-sdk.process.samples` capability. Its native worker samples uptime and peak resident memory every 500 ms. Accepted posts wake the UI loop and arrive as typed messages; the app uses no polling timers.

TypeScript owns startup outcomes, start/stop coordination, exact counters, the complete 16-row byte history and the view. The native capability owns OS readings and the generation-safe posting handle. Stop closes the channel; the worker exits when its next post reports closure. Temporary backpressure drops and counts that sample while sampling continues.

Startup replies before the settled view. A failed native start closes the channel and shows “sampler failed to start”; a refused open never starts an existing producer. Native recording includes the startup outcome and all delivered channel events, so replay reproduces successful and failed starts without launching a worker.

## Run

```sh
native dev
```

## Test

```sh
native test
```

The headless test host deliberately has no OS sampler. It verifies explicit startup failure, cleanup, every initial model byte and sealed replay. The SDK integration suite injects producers and compares the complete native reference, including raw payloads, inactive bytes, exact u64/u32 boundaries, both view backends, backpressure, stale handles and replay:

```sh
zig build test-ts-channel-monitor-e2e
```

## Live verification

```sh
native build -Dautomation=true
./zig-out/bin/channel-monitor &
native automate wait
native automate snapshot
```

Find the Start button's widget id in the snapshot and use `native automate widget-action monitor-canvas ID press`. Verify that sample lines grow without timer subscriptions. Press Stop and verify that the count settles and stays fixed. Capture the retained view with `native automate screenshot monitor-canvas`.
