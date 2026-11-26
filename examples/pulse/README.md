# pulse

A live dashboard: four metrics (revenue, active users, error rate, p95 latency) that move on a
timer, a sparkline per metric, a line chart over the last minute with a hover readout, an activity
feed that fills as events arrive, a pause control and a tick interval. React 19 renders it,
Tailwind 4 styles it, and the pause and interval buttons come from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/pulse
$ NATIVE_STEPS='frame 0 | wait 2200 | print #tick | click #pause | print #live-state' NATIVE_SNAPSHOT=pulse.png ./build/pulse
```
