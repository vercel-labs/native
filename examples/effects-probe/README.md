# effects-probe

The minimal effects dogfood: a TypeScript core and Native markup app whose Start button spawns a long-running shell stream through `Cmd.spawnEvents`, streams each stdout line into the list as a typed `Msg`, and whose Cancel button kills the process mid-stream through `Cmd.cancel`.

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
zig build test-ts-effects-probe-e2e -Dplatform=null
```

The repository suite compares the scriptc-compiled core and both view backends with the retained native reference. It covers complete subprocess and clipboard results, owned payloads, exact 64-bit counters, and sealed session replay through the fake executor.
