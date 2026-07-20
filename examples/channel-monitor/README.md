# channel-monitor

The external-source channel dogfood: a native-rendered app whose Start button opens a channel through `fx.openChannel` and hands the thread-safe `ChannelHandle` to an app-owned worker thread. The worker samples its own process every half second (uptime, peak resident set size) and `post`s each reading; every post wakes the UI loop itself and arrives as one typed `Msg` — **no timer polling anywhere**: no `fx.startTimer`, no shared-queue sweep, no rebuild that was not caused by an event.

This is the standing proof for the channel family's live path: app thread → per-channel non-lossy staging → `wake` → loop-thread drain → `update` → rebuild. Stop closes the channel through `fx.closeChannel`; the worker's next `post` answers `false` and it winds down on its own — the generation-stamped handle makes the detached thread safe past close and even past app teardown.

Back-pressure is part of the story: a refused post (staging full, oversized) returns `false` and the next delivered event carries the drop counters, shown in the status bar.

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

The tests swap the worker for a handle-capturing stub and drive the same `update`: posted bytes land as `.data` Msgs (and no fx timer is ever armed — the no-polling proof), Stop delivers the one `.closed` terminal and kills the handle, and a refused open reports `.rejected` instead of silence.
