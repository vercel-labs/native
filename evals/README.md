# zero-native evals

An eval harness for AI-agent authoring of zero-native apps. It formalizes the "clean-agent trial": give a fresh agent nothing but a scaffolded workspace, the `native-ui` skill, and a task prompt, then grade what it produced deterministically.

Per case the runner:

1. **Scaffolds** a fresh workspace with the repo's own CLI — `zig build` at the repo root, then `zig-out/bin/zero-native init evals/.workspaces/<case> --frontend native` — and delivers the skill exactly the way a real user gets it: `zero-native skills get native-ui` written to the workspace's `.claude/skills/native-ui/SKILL.md` (`init` does not ship skills). The workspace is then **pre-warmed** (`zig build test` once) so the agent's own builds are incremental and its wall-clock isn't spent compiling the framework.
2. **Runs the agent-under-test**: `claude -p "<task prompt>"` headless in the workspace, routed through the Vercel AI Gateway, with a per-run `CLAUDE_CONFIG_DIR` so no user-level memory/plugins/hooks leak in, `--max-turns`, a wall-clock timeout, and the full `stream-json` transcript captured to `results/`.
3. **Grades** with deterministic checks: `zig build test` in the workspace, `zero-native markup check` on the `.zml` files, per-case file greps (e.g. "the board uses `<template>`"), and live automation-snapshot greps (build with `-Dautomation=true`, launch, `zero-native automate wait`, grep `snapshot.txt` for expected roles/names).
4. **Judges** quality the deterministic checks can't see — idiomatic Model/Msg design, template factoring, test meaningfulness — with an `llm_judge` check: a judge model called directly through the gateway scores case-specific criteria 0–10 against the task prompt and the agent's code. Advisory by default (the score is recorded and printed but never fails the case); set `"advisory": false` on a case to make `minScore` a gate. Skipped in `--dry-run`.
5. **Reports** a per-case `result.json` (pass/fail per check, judge scores, durations, model, turns, cost) plus a console summary table.

## Requirements

- macOS (live snapshot checks launch the app; use `--skip-live` elsewhere), Zig 0.16.0, node >= 22, pnpm 10.x.
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

Models are gateway slugs. The coder (agent-under-test) defaults to `anthropic/claude-sonnet-5` (override with `--model` or `ZN_EVAL_MODEL`); the judge defaults to `anthropic/claude-opus-4.8` (override with `--judge-model` or `ZN_EVAL_JUDGE_MODEL`).

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
pnpm eval --sandbox --sandbox-vcpus 8 # bigger sandboxes (2048 MB RAM per vCPU)
pnpm typecheck
```

Cases run in parallel (log lines are prefixed `[case-name]`); `--concurrency` caps how many at once — locally the default is 2 to keep zig builds from thrashing, with `--sandbox` everything runs at once since each has its own VM.

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

### Vercel Sandbox mode

`--sandbox` runs each case in an isolated [Vercel Sandbox](https://vercel.com/docs/sandbox) (Amazon Linux microVM, `node24` runtime): the runner packs the repo **working tree** into a tarball, uploads it, installs zig + pnpm + the Claude Code CLI in the VM, and re-invokes this same harness inside (`pnpm eval --skip-permissions <case>`), then pulls `result.json` and the transcript back into the local `results/` dir. Snapshot checks self-skip (no display); everything else — build+test, markup check, greps, judge — runs as usual. `--dangerously-skip-permissions` is safe there because the whole VM is the throwaway.

Auth: the SDK needs `VERCEL_OIDC_TOKEN`. One-time setup in `evals/`:

```sh
vercel link --scope vercel-labs --project zero-native
vercel env pull .env.local   # the runner auto-loads VERCEL_OIDC_TOKEN from .env.local
```

The OIDC token expires (~12h); re-run `vercel env pull .env.local` when sandbox auth fails.

Real runs exit non-zero if any case fails. Workspaces live in `.workspaces/` and results in `results/<timestamp>/<case>/` (`result.json`, `transcript.jsonl`, the isolated `claude-config/`); both directories are gitignored.

### Permissions for the agent-under-test

By default the agent runs with `--permission-mode acceptEdits` plus an allowlist covering `zig ...`, `zero-native ...`, and basic file commands — enough for unattended edit/build/test loops without granting arbitrary shell. `--skip-permissions` switches to `--dangerously-skip-permissions`; only use it if the default allowlist blocks a case, and remember the workspace is a throwaway dir but the process is not otherwise sandboxed.

## Cases

- `templates-settings-app` — validates the new grammar: repeated grouped toggle sections where `<template>`/`<use>` is the natural shape, plus token style attributes (muted headers, surface cards). Checks: build+tests, markup check, `<template>`/`<use>` greps, token-attribute greps, snapshot roles.
- `kanban-board` — port of the manual builder trial; card identity must survive moving between columns (`global-key`).
- `habits-tracker` — port of the manual markup trial; text entry (elm-style mirror), derived/filtered lists, enum filters.
- `expenses-table` — exercises the newest grammar (every built-in component markup-expressible): an expense ledger whose natural shape is `table` > `table-row` > `table-cell` with `<for>` rows, an exclusive category filter, and an alert-shaped empty state. The prompt describes only requirements (rows-and-columns of data, a callout, pinned display strings); the greps assert the agent reached the table grammar from the skill alone.
- `process-monitor` — exercises the effects surface: a long-running local command (a harmless `sh -c` tick loop the prompt pins exactly) spawned from update through the effects channel, lines streaming into a bounded 12-line list, cancel by model-owned key, and status/counts derived from the line/exit Msgs. Greps assert `.update_fx` wiring, `fx.spawn`/`fx.cancel`, fake-executor tests, and the absence of hand-rolled `std.process.Child`/`std.Thread`; the live snapshot asserts the idle state (Start/Cancel, "Status: idle", "0 lines · 0 dropped") so nothing spawns during grading. The judge scores effect-key discipline, non-blocking behavior, honest drop accounting, and derive-don't-store.
- `release-dashboard` — exercises the pipeline composites and markdown-in-markup: a release dashboard whose natural shape is `<stepper>` for the five-stage track (starting on "Canary"), `<timeline>`/`<timeline-item>` for the seeded event history, and a `<markdown>`-sourced notes panel containing a GFM table. Greps assert all three elements plus `<for>` events; the snapshot asserts the composite semantics (`"Canary (active)"` stepper labels, timeline items by title, `role=gridcell` markdown table cells, the pinned status summary). The judge scores shadcn-ish composition (no ad-hoc reimplementations) and declarative markup.

Add a case by creating `cases/<name>/eval.json` (see `src/types.ts` for the schema). Prompts describe app **requirements**, never the solution — the point is to see whether a fresh agent reaches the intended grammar from the skill alone.

## CI

CI only typechecks the harness (`evals-typecheck` in `.github/workflows/ci.yml`). Eval runs are local/manual — no model calls in CI.
