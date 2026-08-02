# channel-monitor

The external-source channel dogfood: a native-rendered app whose Start button opens a channel through `fx.openChannel` and hands the thread-safe `ChannelHandle` to an app-owned worker thread. The worker samples its own process every half second (uptime, peak resident set size) and `post`s each reading; every post wakes the UI loop itself and arrives as one typed `Msg` — **no timer polling anywhere**: no `fx.startTimer`, no shared-queue sweep, no rebuild that was not caused by an event.

This is the standing proof for the channel family's live path: app thread → per-channel non-lossy staging → `wake` → loop-thread drain → `update` → rebuild. Stop closes the channel through `fx.closeChannel`; the worker's next `post` answers `.closed` and it winds down on its own — the generation-stamped handle makes the detached thread safe past close and even past app teardown.

The launch itself is gated on `handle.live()` — the producer-launch check. Under session replay the open parks and `live()` answers false, so the sampler never spawns and replay stays fully offline; a producer that launched unconditionally would still be stopped at its first post, but only after any pre-post setup already ran. The Msg stream (and the model) is identical either way, because nothing model-visible branches on `live()` — the journaled events are the whole stream.

Back-pressure is part of the story, and the post's answer tells the worker exactly what to do: `.accepted` staged the sample; `.dropped_full` means the staging FIFO pushed back — the sample is dropped and counted (the next delivered event carries the counters, shown in the status bar and status line) but sampling continues, because a transient stall is not a stop; `.dropped_oversized` would be a programming error (this app's samples are bounded far under the post limit); `.closed` is the one answer that ends the loop.

## Run

```bash
native dev
```

## Verify through the automation harness

```bash
native build -Dautomation=true
./zig-out/bin/channel-monitor &
native automate wait
# click Start (find the id in snapshot.txt), watch "sample N" lines grow
# with NO timer subscriptions active, click Stop, verify the count stops.
```

## Test

```bash
native test -Dplatform=null
```

The tests swap the worker for a handle-capturing stub and drive the same `update`: posted bytes land as `.data` Msgs (and no fx timer is ever armed — the no-polling proof), a full staging FIFO answers `.dropped_full` without stopping the monitor (the drop count reaches the status line), Stop delivers the one `.closed` terminal and kills the handle, and a refused open reports `.rejected` instead of silence. Startup is honest in the same way: "monitoring" is claimed only after the source thread actually started — a failed spawn closes the just-opened channel and puts the failure in the status line, exercised through the same injected-source seam. A replay-armed start pins the launch gate: the parked open's handle answers `live() == false` and the source seam is never invoked.
