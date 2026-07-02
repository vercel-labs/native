# effects-probe

The minimal effects dogfood: a native-rendered app whose Start button spawns a long-running shell stream through `fx.spawn`, streams each stdout line into the list as a typed `Msg`, and whose Cancel button kills the process mid-stream through `fx.cancel`.

This is the standing proof for the effect system's live path: worker thread → bounded completion queue → `wake_fn` → loop-thread drain → `update` → rebuild.

## Run

```bash
zig build run
```

## Verify through the automation harness

```bash
zig build -Dplatform=macos -Dweb-engine=system -Dautomation=true
./zig-out/bin/effects-probe &
zero-native automate wait
# click Start (find the id in snapshot.txt), watch "stream line N" grow,
# click Cancel, verify the count stops and the status shows "cancelled".
```

## Test

```bash
zig build test -Dplatform=null
```

The tests drive the same `update` through the fake effect executor: spawn requests are asserted on (argv, key), synthetic lines and exits are fed back as dispatched Msgs, and cancel semantics are proven without running a process.
