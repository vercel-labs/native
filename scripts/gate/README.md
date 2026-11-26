# Quality scorecard

This directory measures a set of quality bars and writes a scorecard, so progress is a number
instead of a feeling.

```console
$ node scripts/gate/gate.mjs --out build/scorecard
```

It writes `SCORECARD.md` and `scorecard.json` to the output directory, with every gate's bar, the
number measured today, pass or fail, and — for each failing gate — the three gaps to close first
and the code area each lives in. `run.log` holds the run's progress; `shots/` holds the native,
Chrome and diff images the parity gate compared.

The bars, the WPT subset and its revision, and the per-example scenarios are in
[bars.json](./bars.json). Change the bars there; the scorecard prints them, so a moved bar shows up
in the diff.

## The gates

| Gate | What it measures | How |
|---|---|---|
| 1. Smoothness | p95 frame time ≤ 16.7 ms on every example, scrolling, animating, and in the three.js scenes | each app runs headlessly with `NATIVE_FRAME_TIMES=1` through 240 frames 16 ms apart plus wheel steps, and the host's per-frame composite time is added to the runtime's stages |
| 2a. HTML/CSS | pass rate on a fixed WPT subset | `native wpt run` over the directories and revision in `bars.json`, in a checkout of its own under the output directory |
| 2b. Chrome diff | how much of each example's first frame Chrome would draw the same way | the app is bundled for the browser with the esbuild the CLI already depends on, loaded from a directory holding the app and its files, screenshotted at the page's own window size at 2×, and compared with the native snapshot pixel by pixel |

An example whose frame is animation content rather than a rendering rule is reported but not judged:
`chrome.timingSensitive` in `bars.json` lists them, with the reason in `chrome.timingSensitiveNote`.
`canvas-particles` is one — its field is seeded and its primitives probe equal to Chrome's, but every
mote moves each frame, so a pixel or two of accumulated motion moves most of the differing pixels
and the score varies run to run.
| 3. Compile time | cold and warm `native build` per example | the app's own build record and build cache removed for the cold build, with the compiler's cache primed once at the start of the run so each number is the app's own compile; the phase times come from the build's own progress lines |
| 4. Hot reload | a TypeScript edit to the reloaded page | `native dev` on three examples, an edit appended to the app's script, timed by the `reloaded scripts in N ms` line the dev command prints |
| 5. React + UI SDK | how many UI SDK screens compile, run, and match Chrome | the builds and parity from above, plus an optional `--screens` report from another run |

Gates share their builds: a run that measures smoothness, parity or hot reload builds the examples
once (cold, then warm) and reuses the executables.

## Running one gate, or adding to a scorecard

```console
$ node scripts/gate/gate.mjs --out build/scorecard --only coverage
$ node scripts/gate/gate.mjs --out build/scorecard --only smoothness,uisdk --examples counter,todo
$ node scripts/gate/gate.mjs --out build/scorecard --only reload --merge
```

`--reuse` keeps the example builds and timings an earlier run recorded, `--merge` adds this run's
gates to the scorecard already in the output directory, and `--screens <SCOREBOARD.md>` (or
`NATIVE_GATE_SCREENS`) folds screen counts another run measured into gate 5.

`--label NAME` records a compile run's cold times in the output directory as
`compile-NAME.json`; the scorecard prints one cold-build column per label, so the same examples
timed on another host or with another compiler sit beside the first.

## Chrome

The parity gate uses Chrome from `CHROME_BIN`, a `@puppeteer/browsers` install under the output
directory, or a system Chrome. To fetch one into the output directory:

```console
$ npx @puppeteer/browsers install chrome@stable --path build/scorecard/browsers
```

Without Chrome the gate reports parity as unmeasured and the rest of the scorecard still runs.

## Requirements

Node.js 24 and a built CLI (`pnpm --filter @native-sdk/cli build`). The coverage gate fetches its
own WPT checkout at the revision in `bars.json` under the output directory, and needs the host
libraries the WPT docs list. Hot reload needs a desktop session for `native dev` to open its
window. Builds use the scriptc the workspace installed; `--scriptc` (or `NATIVE_SCRIPTC`) points
them at another compiler's executable, such as a build of scriptc main.
