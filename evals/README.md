# Native SDK evals

An eval harness for AI-agent authoring of Native SDK apps. It formalizes the "clean-agent trial": give a fresh agent nothing but a scaffolded workspace, the `native-ui` skill, and a task prompt, then grade what it produced deterministically.

Per case the runner:

1. **Scaffolds** a fresh workspace with the repo's own CLI — `zig build` at the repo root, then `zig-out/bin/native init evals/.workspaces/<case> --frontend native` (`--template zig-core` for the pre-existing native cases and the zig side of dual cases, `--template ts-core` for the ts side) — and delivers each track's skills exactly the way a real user gets them: `native skills get <name>` written to `.claude/skills/<name>/SKILL.md` (`init` does not ship skills). The zig track gets `native-ui` + `zig`; the ts app track gets `ts-core` + `native-ui`; core-only ts-core cases get `ts-core`. The workspace is then **pre-warmed** (`native test` once — workspaces are zero-config, so builds go through the CLI verbs) so the agent's own builds are incremental and its wall-clock isn't spent compiling the SDK.
2. **Runs the agent-under-test**: `claude -p "<task prompt>"` headless in the workspace, routed through the Vercel AI Gateway, with a per-run `CLAUDE_CONFIG_DIR` so no user-level memory/plugins/hooks leak in, `--max-turns`, a wall-clock timeout, and the full `stream-json` transcript captured to `results/`.
3. **Grades** with deterministic checks: `native test` in the workspace, `native markup check` on the `.native` files, per-case file greps (e.g. "the board uses `<template>`"), and live automation-snapshot greps (`native build` with `-Dautomation=true`, launch, wait for the automation snapshot, grep it for expected roles/names).
4. **Judges** quality the deterministic checks can't see — idiomatic Model/Msg design, template factoring, test meaningfulness — with an `llm_judge` check: a judge model called directly through the gateway scores case-specific criteria 0–10 against the task prompt and the agent's code. Advisory by default (the score is recorded and printed but never fails the case); set `"advisory": false` on a case to make `minScore` a gate. Skipped in `--dry-run`.
5. **Reports** a per-case `result.json` (pass/fail per check, judge scores, durations, model, turns, cost) plus a console summary table.

## Requirements

- macOS (live snapshot checks launch the app; use `--skip-live` elsewhere, or `--sandbox` for the Linux lane), Zig 0.16.0, node >= 24, pnpm 10.x.
- The [Claude Code CLI](https://code.claude.com/docs) (`claude`) on PATH.
- A [Vercel AI Gateway](https://vercel.com/docs/ai-gateway) API key for real runs:

```sh
export AI_GATEWAY_API_KEY="vck_..."   # or VERCEL_AI_GATEWAY_API_KEY
```

The runner assembles the gateway env for the claude subprocess per [Vercel's Claude Code guide](https://vercel.com/docs/ai-gateway/coding-agents/claude-code):

```sh
ANTHROPIC_BASE_URL=https://ai-gateway.vercel.sh
ANTHROPIC_AUTH_TOKEN=$AI_GATEWAY_API_KEY
ANTHROPIC_API_KEY=            # empty string on purpose: a non-empty value would win over the auth token
```

Models are gateway slugs. The coder (agent-under-test) defaults to `anthropic/claude-sonnet-5` (override with `--model` or `NATIVE_SDK_EVAL_MODEL`); the judge defaults to `anthropic/claude-opus-4.8` (override with `--judge-model` or `NATIVE_SDK_EVAL_JUDGE_MODEL`). Both tracks of a dual case always run with the SAME coder model — fairness is a property of the run, so set it once at run time.

## Usage

```sh
cd evals
pnpm install

pnpm eval --list                      # list cases
pnpm eval --dry-run                   # everything except the model call (no key needed):
                                      #   scaffold + skill delivery, print env + claude argv,
                                      #   run the graders against the untouched scaffold
                                      #   (grader FAILs are expected there and exit 0)
pnpm eval templates-settings-app      # one real run
pnpm eval                             # the whole suite
pnpm eval --model anthropic/claude-opus-4.8 templates-settings-app
pnpm eval --judge-model anthropic/claude-fable-5 templates-settings-app
pnpm eval --skip-live                 # skip snapshot checks (no app launch / non-macOS)
pnpm eval --track ts dual-feed-table  # one track of a dual-track case (default: both)
pnpm eval --keep-workspaces           # keep .workspaces/<case> around for inspection
pnpm eval --trials 5 expenses-table   # 5 independent trials per case; report pass rates
pnpm eval --concurrency 3             # run up to 3 case trials in parallel (default 2 locally)
pnpm eval --sandbox                   # run each case in its own Vercel Sandbox microVM
pnpm eval --sandbox --dry-run         # full sandbox path minus the model call
pnpm eval --sandbox --sandbox-vcpus 8 # bigger sandboxes (2048 MB RAM per vCPU)
pnpm typecheck
```

Cases run in parallel (log lines are prefixed `[case-name]`); `--concurrency` caps how many at once — locally the default is 2 to keep zig builds from thrashing, with `--sandbox` the default is 4 (each case has its own VM, but plans rate-limit vCPU allocation).

### Trials

Model runs are stochastic; a single pass or fail is weak evidence. `--trials <n>` runs each case n times, each trial **fully independent** — its own scaffolded workspace (`.workspaces/<case>-trial-<n>`), its own agent run, its own checks and judge call — and reports per-case pass **rates** (e.g. `3/5`), per-check pass counts, and the mean judge score. Trials share the `--concurrency` pool (log lines are prefixed `[case-name#trial]`), and with `--sandbox` each trial gets its own microVM.

With `--trials 1` (the default) the behavior and file layout are exactly the single-run layout described above. With `--trials > 1` each case directory nests per-trial results plus an aggregate:

```
results/<stamp>/
  summary.json                      # array of per-case aggregates
  <case>/
    aggregate.json                  # pass rate, per-check pass counts, mean judge score, per-trial results
    trial-1/result.json             # exactly a single-run result.json (plus a "trial" field)
    trial-1/transcript.jsonl
    trial-2/...
```

The summary table swaps the PASS/FAIL column for a `pass rate` column, the `checks` column shows per-check pass counts (`3/3 2/3 ...`, `s` = skipped in every trial), `judge` is the mean score, `cost`/`time` are totals across trials, and a per-check breakdown is printed under the table. A real run exits non-zero if any trial failed.

### Lanes

Every result carries a **lane** — where the case ran and got graded — and the summary table has a lane column:

- `macos-local` (default): the run described above; live snapshot checks launch the app directly and require macOS.
- `linux-sandbox` (`--sandbox`): each case trial runs in its own isolated [Vercel Sandbox](https://vercel.com/docs/sandbox) microVM booted from a pre-baked Linux image, **including the live checks** — the app builds with `-Dplatform=linux -Dweb-engine=system -Dautomation=true`, launches under Xvfb, and is driven through the same automation dropbox the macOS lane uses. An engine screenshot of the app's gpu_surface is captured through the dropbox and pulled back with the results.

A check that greps a surface which exists on only one OS can declare `"lanes": ["macos-local"]` in `eval.json`; on other lanes it reports **skipped** (`not graded on the ... lane`) instead of failing, so the summary distinguishes "fails" from "not applicable on this lane". Audited 2026-07-05: none of the ten shipped cases needs a lane annotation — every snapshot pattern asserts roles/names from the SDK's own automation snapshot, and the surfaces they cover (secondary windows, gpu charts, trees, tables) are proven on Linux by `tools/linux-truth/`. A Linux-lane failure is therefore a real failure until a case says otherwise.

### Vercel Sandbox mode

`--sandbox` boots each case trial from a custom image (see `evals/sandbox/`) that bakes the Linux GUI stack (GTK4 + WebKitGTK + Xvfb), zig, node/pnpm, the Claude Code CLI, and a **pre-warmed build layer**: the repo at a pinned ref with the CLI, workspace-test, and automation build graphs already compiled into fixed cache paths. Per case the runner then:

1. uploads the repo **working tree** as a tarball and rsyncs it over the baked repo — deletions propagate, caches survive, so builds against the current tip are incremental on top of the bake;
2. starts Xvfb and re-invokes this same harness inside (`pnpm eval --skip-permissions --lane linux-sandbox <case>`) with the gateway env assembled exactly like a local run;
3. pulls the whole case results directory home — `result.json`, `transcript.jsonl`, `live-*.png` engine screenshots — before the microVM is destroyed.

`--dangerously-skip-permissions` is safe there because the whole VM is the throwaway. `--sandbox --dry-run` exercises the entire path — provisioning, refresh, scaffold, graders (which FAIL against the untouched scaffold, as designed), artifact pull — without the model call, and exits 0.

**Image**: build and push once with `evals/sandbox/build-image.sh` (needs a Docker login to the registry — the two token variants are in the script header). Rebuild when the Dockerfile changes, when zig bumps, or when the tip has drifted far enough from the baked ref that in-sandbox builds stop feeling incremental; runs stay *correct* without a rebuild because of the working-tree refresh. After a push the registry prepares the image for a few minutes; the runner retries `image_not_ready` for up to 10 minutes. `--sandbox-image` overrides the default reference (`eval-sandbox`, resolved in the linked project).

**Auth** (checked before any sandbox work): either an OIDC token — one-time setup in `evals/`:

```sh
vercel link --scope vercel-labs --project zero-native
vercel env pull .env.local   # the runner auto-loads VERCEL_OIDC_TOKEN from .env.local
```

(the token expires ~12h; re-run `vercel env pull .env.local` when sandbox auth fails) — or `VERCEL_TOKEN` + `VERCEL_TEAM_ID` + `VERCEL_PROJECT_ID` for environments where OIDC is unavailable. Real runs additionally need `AI_GATEWAY_API_KEY` as usual.

**Cost and limits**: sandbox compute is metered (active CPU + provisioned memory) — a 4-vCPU case trial that runs 20-30 minutes lands around $0.20-0.35 plus the model tokens through the gateway. Sandboxes cap at 45 minutes wall clock on the Hobby plan (the runner's per-sandbox timeout), and vCPU allocation is rate-limited per plan, which is why the default `--concurrency` in sandbox mode is 4.

Real runs exit non-zero if any case fails. Workspaces live in `.workspaces/` and results in `results/<timestamp>/<case>/` (`result.json`, `transcript.jsonl`, the isolated `claude-config/` — kept in-VM and not pulled for sandbox runs, plus `live-*.png` screenshots from the Linux lane); both directories are gitignored.

### Permissions for the agent-under-test

By default the agent runs with `--permission-mode acceptEdits` plus an allowlist covering `zig ...`, `native-sdk ...`, and basic file commands — enough for unattended edit/build/test loops without granting arbitrary shell. `--skip-permissions` switches to `--dangerously-skip-permissions`; only use it if the default allowlist blocks a case, and remember the workspace is a throwaway dir but the process is not otherwise sandboxed.

In both modes the runner passes `--disallowedTools` deny rules for `evals/cases/**` and `evals/results/**`: the workspace references the SDK repo by path, so the harness itself is reachable from the agent's cwd, and agents exploring the repo for docs/examples were observed reading their own grading config (3/20 runs of the 2026-07-04 suite). SDK source and examples stay readable on purpose — a real user has the repo.

## Cases

- `templates-settings-app` — validates the new grammar: repeated grouped toggle sections where `<template>`/`<use>` is the natural shape, plus token style attributes (muted headers, surface cards). Checks: build+tests, markup check, `<template>`/`<use>` greps, token-attribute greps, snapshot roles.
- `kanban-board` — port of the manual builder trial; card identity must survive moving between columns (`global-key`).
- `habits-tracker` — port of the manual markup trial; text entry (elm-style mirror), derived/filtered lists, enum filters.
- `expenses-table` — exercises the newest grammar (every built-in component markup-expressible): an expense ledger whose natural shape is `table` > `table-row` > `table-cell` with `<for>` rows, an exclusive category filter, and an alert-shaped empty state. The prompt describes only requirements (rows-and-columns of data, a callout, pinned display strings); the greps assert the agent reached the table grammar from the skill alone.
- `process-monitor` — exercises the effects surface: a long-running local command (a harmless `sh -c` tick loop the prompt pins exactly) spawned from update through the effects channel, lines streaming into a bounded 12-line list, cancel by model-owned key, and status/counts derived from the line/exit Msgs. Greps assert `.update_fx` wiring, `fx.spawn`/`fx.cancel`, fake-executor tests, and the absence of hand-rolled `std.process.Child`/`std.Thread`; the live snapshot asserts the idle state (Start/Cancel, "Status: idle", "0 lines · 0 dropped") so nothing spawns during grading. The judge scores effect-key discipline, non-blocking behavior, honest drop accounting, and derive-don't-store.
- `release-dashboard` — exercises the pipeline composites and markdown-in-markup: a release dashboard whose natural shape is `<stepper>` for the five-stage track (starting on "Canary"), `<timeline>`/`<timeline-item>` for the seeded event history, and a `<markdown>`-sourced notes panel containing a GFM table. Greps assert all three elements plus `<for>` events; the snapshot asserts the composite semantics (`"Canary (active)"` stepper labels, timeline items by title, `role=gridcell` markdown table cells, the pinned status summary). The judge scores house-style composition (no ad-hoc reimplementations) and declarative markup.
- `settings-picker` — exercises the anchored floating surface pattern: two picker rows (Theme/Accent) whose natural shape is a `<select>` trigger + `<if>`-mounted `<dropdown-menu anchor=...>` of `<menu-item>`s with `on-dismiss`, model-owned open state, and an exclusive-open rule. Greps assert the select/anchored-dropdown/on-dismiss/menu-item composition; the snapshot asserts the closed idle state and the pinned status line (the trigger's accessible name may be its value text or an explicit `label` — both legit, the pattern allows either).
- `file-browser-panes` — exercises split panes and the tree keymap: a resizable two-pane browser (`<split value= on-resize=>` with pane `min-width` floors) whose sidebar is a `<tree>` of `role="treeitem"` rows with model-owned `expanded` state driving a detail pane. The snapshot asserts `role=separator`/`role=tree`/`role=treeitem`, the seeded rows, and the pinned selection status. The judge is explicitly told the tree keymap is engine-provided so it never expects app-side keyboard Msgs.
- `metrics-dashboard` — exercises the markup chart element and icon-in-button: the whole view is markup (header with `<button icon=...>`, the `<chart>` with a `<series values="{binding}">`, status bar) and the Zig side owns only model/update logic. Greps assert `<chart`, `icon="`, and the pinned `y-min="0"`; the snapshot asserts `role=chart` plus the seeded summary.
- `inspector-window` — exercises model-declared secondary windows: a task list whose inspector opens as a real second OS window through `Options.windows_fn` + `window_view`, live-updates with the selection, reflects a user close via `on_close`, and never duplicates. A negative grep rejects faking it with `<dialog>`/`<sheet>`/`<drawer>`.
- `disk-status-spans` — exercises inline text spans: one wrapped paragraph mixing bold, muted, and monospace runs (announcing as a single text run), with bound values interpolated inside the spans and a derived percentage summary. Greps assert the three span styles inside one enclosing `<text>`; the snapshot asserts the paragraph as ONE combined text run with resolved bindings.
- `chat-composer` — exercises the composer composites: an `<input-group>` wrapping a `<textarea>` plus an in-border `<input-group-actions>` row, an attached `<button-group>` cluster, a derived disabled Send, and a `<for>` message list. The snapshot asserts the composer textbox, the attached cluster, Send disabled on the empty draft, the seeded messages, and the live count.
- `brand-icon-package` — exercises the one-image app-icon pipeline through `native package`: the manifest sources icons from a single square PNG at the brand path, no prebuilt icon containers anywhere, and the packaged macOS bundle carries a generated `AppIcon.icns` wired into its metadata.
- `playlist-row-actions` — exercises the interaction seams: row-level Enter as a list row's primary action (`on-submit` on `list-item`, distinct from select-on-press) and the app-level key fallback (`Options.on_key`) for Space and the arrows when nothing is focused. Greps assert the row-level submit binding and the fallback wiring; the snapshot asserts the seeded rows, the model-driven selection, and the idle derived status.

Add a case by creating `cases/<name>/eval.json` (see `src/types.ts` for the schema). Prompts describe app **requirements**, never the solution — the point is to see whether a fresh agent reaches the intended grammar from the skill alone.

## The TS-authoring track

Cases with `"frontend": "ts-core"` measure the other authoring surface: the app core written in the TypeScript subset and compiled by `packages/core`. The scaffold is not an app — it is `src/core.ts` (the case's `starter/` overlay when it ships one, else a minimal counter core), a README with the check loop, and the `ts-core` skill delivered via `native skills get ts-core`. Two graders replace build/markup/snapshot:

- `ts_transpile` — the transpiler must exit clean on `src/core.ts`: tsc-semantics typecheck, every subset rule (NS1001-NS1050), Zig emission. Failing diagnostics stay in the result as the violation evidence.
- `ts_harness` — behavioral grading: transpile the core, assemble a scratch dir with the emitted `core.zig`, the rt kernel, and the case's `harness.zig`, then `zig test harness.zig`. The harness drives the real dispatch cycle (`update` → `commitModelRoot` → `frameReset`) and asserts the prompt's requirements, so the case prompt pins the Model/Msg/export contract exactly (an API spec, not a solution).

Because the grading harness compiles against the agent's code, ts-core prompts pin names; behavior stays requirements-only. The transpiler compiles pure `update(model, msg): Model` cores and effectful `Model | [Model, Cmd<Msg>]` pair-returns (the Cmd surface); the wave-2 dual-track cases below are the effects coverage.

The ts-core cases:

- `ts-habits-core` — a fresh core from a requirements description (the TS mirror of `habits-tracker`): seeded habits, toggle-with-streak math, a trimmed draft add path, exclusive filters, derived counts.
- `ts-expenses-filter` — a feature-add to an existing subset file: extend a working expense ledger (shipped as `starter/`) with an exclusive `Category | null` filter and derived filtered views, without breaking the existing behavior.
- `ts-countdown-bugfix` — a bug-fix in an existing subset file: a countdown core whose tick/reset/set_duration transitions drifted from the spec (unguarded ticks, no completion stop/floor, hardcoded reset); the prompt states the intended behavior, the harness isolates each drift.
- `ts-tag-input-core` — the text seam under pressure: comma-separated tag parsing with byte-level trim, empty-drop, and case-insensitive dedupe, where string methods are the reflex and NS1004 says no.

## The dual-track cases (wave 2)

Wave 1's four ts-* cases measured subset compliance on toy katas and compared against Zig numbers gathered **before** the `zig` 0.16-idioms skill existed. Wave 2 replaces that comparison with an honest, contemporaneous one: six realistic asks, each ONE language-blind spec (`"frontend": "app-dual"`) that runs on **both authoring tracks** — `<case>@ts` scaffolds a full TypeScript app (`native init --frontend native --template ts-core`), `<case>@zig` the Zig app template (`--template zig-core`). Identical prompt, identical shared checks, one behavioral spec asserted by two thin per-track harnesses; `--track ts|zig` selects a lane, the default runs both.

Grading per track: the shared checks (`native test -Dplatform=null`, markup check, view greps, the judge with a case rubric) plus the track's behavioral harness. On the ts track, `ts_harness` transpiles `src/core.ts` (its whole import graph) and `zig test`s the case's `harness-ts.zig` against the emitted core, the rt kernel, and `harness-lib/cmdview.zig` — a decoder over the Cmd/Sub wire format, so harnesses assert effects semantically ("one GET to the pinned URL", "the delay re-armed on the same key"). On the zig track, `zig_harness` injects the case's `harness-zig.zig` into the workspace as `src/eval_behavior_spec.zig` (a test import appended to `src/main.zig`, restored afterward) and runs `native test`, so it compiles against the agent's real Model/Msg/update and drives the SDK's deterministic **fake effects executor** (`fx.executor = .fake`, `pendingSpawnAt`/`feedLine`/`feedExit`/`fireTimer`/`feedResponse`/`feedFileResult`).

The cases — every prompt reads like a real user ask, and every effect result is fed by the harness (no network, no processes, no clocks during grading):

- `dual-feed-table` — "fetch JSON from this API and show it in a sortable table": the HTTP effect (pinned URL, buffered GET, keyed), JSON parsing of a pinned flat schema, two sort orders derived at view time, and the five honest states (idle / loading with re-entry guarded / loaded / explicit empty / failed keeping previous rows) across non-200, transport-failure, and malformed-body deliveries.
- `dual-notes-autosave` — "add debounced autosave to this notes app" (starter provided per track, both riding the SDK text-input engines): the keyed one-shot re-arm debounce (Cmd.delay / fx.startTimer replace), byte-exact notes.tsv serialization, Save now with the pending autosave cancelled, a five-state save lifecycle, and the late-result race (a save landing after newer edits must not mark them saved).
- `dual-pomodoro-timer` — "build a pomodoro timer with a completion sound": the recurring timer surface (Sub.timer declared from the model / fx timer armed-cancelled through the channel — armed exactly while running), auto-advancing focus/rest state machine, work-only completion counting, stale-tick guards, and the audio surface at completions.
- `dual-list-delete-fix` — "this list doesn't update after delete — fix it": a realistic seeded bug (a hand-maintained visible-list cache that delete forgot) in a medium app with a markup view; the harness pins list correctness across delete/toggle/add/filter, the judge scores whether the fix is the derive-don't-store root cause or a symptom patch.
- `dual-ledger-csv-split` — "split this core into modules and add export-to-CSV in the new module": multi-file authoring (relative imports on ts, `@import` on zig, both grepped), byte-exact CSV quoting (commas and doubled quotes exercised by the seeds), the file-write effect, and a four-state export lifecycle.
- `dual-sysinfo-panel` — "show system info from a shell command in the UI": a collect-mode background spawn of a pinned argv, byte parsing of the output line, re-entry guarded while probing, and honest ok / failed-with-code / never-started states.

Starters (`starter-ts/`, `starter-zig/`) overlay the scaffold for the feature-add, bug-fix, and split cases — written in each track's idiom (immutable spread cores over the SDK text engine on ts; bounded buffers, `canvas.TextBuffer`, and Model-method bindings on zig) so neither track starts from translated code.

**Fairness and methodology.** Both tracks get identical prompts (language-neutral asks; the pinned contract names arms/fields in the wire spelling and states each track's idiom for the few surfaces that necessarily differ — routed err arms on ts vs payload-carried outcomes on zig). Each track gets its CURRENT skill set by the documented delivery path and nothing extra: ts → `ts-core` + `native-ui`; zig → `native-ui` + `zig` (the 0.16-idioms skill). The same coder model grades both tracks of a run. Known caveats to carry into any writeup: wave-1's Zig numbers predate the `zig` skill (this suite is the corrected baseline — the pre-existing native cases now also receive it, so their history splits at this commit); the behavioral harnesses are compiled contracts, so a run can fail for contract-shape reasons the prompt pins explicitly; and the two tracks' harness glue differs by necessity (wire-format decoding vs fake-executor introspection) while asserting the same spec, test for test.

### Authoring metrics

`pnpm metrics results/<stamp> [...]` post-processes finished runs' transcripts into the agent-authoring metrics the checks cannot see, per case and per track — **ts** (the ts-core cases and the `@ts` side of dual cases) vs **zig** (the pre-existing native cases and the `@zig` side): **first-pass compliance** (did the agent's first compliance check after touching sources pass — the transpiler run, `native check`, `native test`, or `native build` on the ts track; `native test` / `native build` / `native check` / `native markup check` on the zig track), **retries-to-green** (failing compliance runs before the first green), **teaching-error encounters** (failing compliance runs that carried a teaching diagnostic — the "did the diagnostics work" round-trip count wave 2 compares across tracks), **violation taxonomy** (NS/TS rule IDs on the ts track; zig error lines on the zig track, with `no member named 'X'` bucketed by member so the 0.16-idiom class is visible) raw and per 1k generated LOC (lines written through Write/Edit to source files, `.native` markup included), and **task success** (the run's own pass verdict). Harness friction — permission-refused commands, errored compounds with no diagnostic in the output — is dropped from the event stream so it never masquerades as an authoring failure. It writes `authoring-metrics.json` next to each `summary.json`.

## CI

CI only typechecks the harness (`evals-typecheck` in `.github/workflows/ci.yml`). Eval runs are local/manual — no model calls in CI.
