# effects-probe

The minimal effects dogfood: a native-rendered app whose Start button spawns a long-running shell stream through `fx.spawn`, streams each stdout line into the list as a typed `Msg`, and whose Cancel button kills the process mid-stream through `fx.cancel`.

This is the standing proof for the effect system's live path: worker thread → bounded completion queue → `wake_fn` → loop-thread drain → `update` → rebuild.

The stream command is platform-conditional: `/bin/sh` paces one line every 200ms on POSIX; Windows builds use `cmd /c for /L` paced by `ping -n 2 127.0.0.1` (~1 line/s), which also works under Wine — `.github/scripts/windows-effects-smoke.sh` cross-compiles this app for `x86_64-windows-gnu` and proves the spawn/stream/wake/cancel path against the automation snapshot there.

## Run

```bash
native dev
```

## Verify through the automation harness

```bash
native build -Dautomation=true
./zig-out/bin/effects-probe &
native automate wait
# click Start (find the id in snapshot.txt), watch "stream line N" grow,
# click Cancel, verify the count stops and the status shows "cancelled".
```

## Test

```bash
native test -Dplatform=null
```

The tests drive the same `update` through the fake effect executor: spawn requests are asserted on (argv, key), synthetic lines and exits are fed back as dispatched Msgs, and cancel semantics are proven without running a process.
