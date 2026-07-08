# Native SDK evals

An eval harness for AI-agent authoring of Native SDK apps. It formalizes the "clean-agent trial": give a fresh agent nothing but a scaffolded workspace, the `native-ui` skill, and a task prompt, then grade what it produced deterministically.

Per case the runner:

1. **Scaffolds** a fresh workspace with the repo's own CLI — `zig build` at the repo root, then `zig-out/bin/native init evals/.workspaces/<case> --frontend native` — and delivers the skill exactly the way a real user gets it: `native skills get native-ui` written to the workspace's `.claude/skills/native-ui/SKILL.md` (`init` does not ship skills). The workspace is then **pre-warmed** (`native test` once — workspaces are zero-config, so builds go through the CLI verbs) so the agent's own builds are incremental and its wall-clock isn't spent compiling the SDK.
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

Models are gateway slugs. The coder (agent-under-test) defaults to `anthropic/claude-sonnet-5` (override with `--model` or `NATIVE_SDK_EVAL_MODEL`); the judge defaults to `anthropic/claude-opus-4.8` (override with `--judge-model` or `NATIVE_SDK_EVAL_JUDGE_MODEL`).

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

## CI

CI only typechecks the harness (`evals-typecheck` in `.github/workflows/ci.yml`). Eval runs are local/manual — no model calls in CI.
