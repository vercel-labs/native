# Web platform tests

`native wpt` runs [web-platform-tests](https://github.com/web-platform-tests/wpt), the conformance suite browsers share, against Native SDK:

```console
$ node compiler/cli.ts wpt fetch                 # sparse checkout into ~/.cache/native/wpt
$ node compiler/cli.ts wpt run                   # all default directories
$ node compiler/cli.ts wpt run css/css-flexbox --filter align --verbose
$ node compiler/cli.ts wpt run --jobs 4             # parallel batches (default: CPU count - 2, at most 8, and only as many as memory holds)
```

To debug one test, `wpt show` prints its diagnostics and the pixel or layout result, and writes the test, the reference and a diff (differing pixels in red) side by side into one PNG:

```console
$ node compiler/cli.ts wpt show css/css-flexbox/align-content-001.htm
```

- **Reftests:** the test page and its reference are rendered at 800×600 and compared pixel by pixel, honoring `<meta name=fuzzy>`.
- **Layout tests:** `check-layout-th.js` tests are checked against `native`'s own layout boxes (`data-expected-*`, `data-offset-*`), without running testharness.js.
- **Crash tests:** a `-crash` page has no reference; it passes when it builds and renders without taking the process down. Its scripts aren't run, as a reftest's aren't.
- **Skips:** a test whose page or reference uses something `native` reports as unsupported is skipped, with that feature as the reason. The report lists the reasons that block the most tests, as a to-do list.
- **Scripts:** a page's classic scripts — inline ones and external files inside the checkout — are compiled with scriptc into one module per page and run in document order once the page's DOM is built, so a script sees and changes the page as it would in a browser. The page's scripts share one scope, as they share the window's in a browser, and an element's `id` is a global of the same name (HTML's named access on the window), so `child.style` works for `<div id="child">`. `<body onload>` runs as a load handler, and the page's other `on*` attributes are attached to their elements before its scripts run. A page whose scripts don't compile stays a skip, with scriptc's error as the reason, so one bad page doesn't stop its batch. Scripts are JavaScript, so they're compiled as `.js`: an API the runtime doesn't have is a runtime error in the page, not a compile error.
- **`reftest-wait`:** after the page's scripts run, the runner fires the load events and then runs timers, microtasks and animation frames until the root element's `reftest-wait` class is removed, with a timeout; only then is the page snapshotted. The reference page goes through the same flow. A page that still holds the class when the timeout runs out is reported as an error, not compared, as WPT's runner fails such a test too.
- **Batching:** runnable pages are compiled in batches into one native runner per batch, a hundred pages at a time by default. Runners compile at scriptc's dev posture — `-O0` with its cached LLVM object shards — so a batch pays for the runtime once and reuses the shards every later batch compiled, and compiles its own pages on top; a page renders the same either way. The number of batches built at once is bounded by available memory as well as by cores, since a build holds a few gigabytes, and each batch's directory and its type-checker daemon are released when the batch is done. A batch whose build fails for a reason scriptc attributes to no page is halved a few times to find the page that breaks it, and what is left is reported as build failures, so one internal error costs a bounded number of builds.

Results are written to `wpt/results.json`, which is committed so progress shows up in diffs.

Before committing a change, check that nothing that passed before has regressed:

```console
$ node compiler/cli.ts wpt run
$ node tests/wpt-regressions.ts HEAD wpt/results.json
```

## Linux

`native wpt` also runs on Linux. The runner compiles the host in `host/linux.c` instead of the windowed macOS host. Pages lay out there and paint into an offscreen surface with Cairo, and text is shaped by HarfBuzz and drawn with FreeType from the `@font-face` files a page registers and the system fonts fontconfig resolves, so reftests are compared pixel by pixel as on macOS. There is no window and no event pump: the window and input calls do nothing, though the page's accessibility tree is still published on the AT-SPI bus when a session bus has one, so a screen reader or inspection tool reaches it headlessly. WebGL 2 is real headlessly too: each canvas gets an EGL surfaceless context on desktop OpenGL (Mesa's llvmpipe where there is no GPU), and the drawing buffer is read back into the canvas bitmap the same way the macOS host reads its CGL context back.

The host needs the headers and libraries it links, which come from these packages:

```console
$ sudo apt-get install libcairo2-dev libfreetype-dev libfontconfig-dev libharfbuzz-dev libpng-dev libjpeg-dev libgif-dev libdbus-1-dev libasound2-dev libsqlite3-dev libegl-dev libgl-dev libgl1-mesa-dri
```

A Linux run writes `wpt/results-linux.json` by default, so its results sit beside the committed macOS ones instead of replacing them. `--out` selects another file as usual.

Each batch compiles to one native runner, and a run builds `--jobs` batches at once, so peak memory grows with both: `--jobs 2 --batch 50` stays inside 32 GB, where eight jobs of the default batch size do not.

Check the layout tests against the committed macOS results with the same gate, restricted to layout tests:

```console
$ node compiler/cli.ts wpt run
$ node tests/wpt-regressions.ts origin/next wpt/results-linux.json --layout
```

A reftest is compared with a reference the same host draws, so a reftest that passes on macOS can come out differently on Linux; without `--layout` the gate counts each of those as a lost pass.

Compiled runner binaries are cached in `~/.cache/native/wpt-runners`, keyed by a hash of the runtime, shared and host sources, the scriptc version and each batch's generated code. A run of the same code from any checkout reuses them, so a re-run after a docs-only change, or a second checkout verifying the same commit, skips scriptc entirely. Delete the directory to reclaim space. A runner says how many pages it holds before it runs any of them, so one that doesn't match the batch it was fetched for is built again from source, and its cache entry replaced, instead of its pages being reported as crashes.

Only a few full runs build and run batches at once machine-wide: each run takes one of `NATIVE_WPT_SLOTS` (default 2) slots in `~/.cache/native/wpt-slots` and waits for one to free up. Several checkouts running WPT together then take turns instead of thrashing the CPU, which gets each run done far sooner.
