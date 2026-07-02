# zero-native evals

An eval harness for AI-agent authoring of zero-native apps. It formalizes the "clean-agent trial": give a fresh agent nothing but a scaffolded workspace, the `native-ui` skill, and a task prompt, then grade what it produced deterministically.

Per case the runner:

1. **Scaffolds** a fresh workspace with the repo's own CLI — `zig build` at the repo root, then `zig-out/bin/zero-native init evals/.workspaces/<case> --frontend native` — and delivers the skill exactly the way a real user gets it: `zero-native skills get native-ui` written to the workspace's `.claude/skills/native-ui/SKILL.md` (`init` does not ship skills).
2. **Runs the agent-under-test**: `claude -p "<task prompt>"` headless in the workspace, routed through the Vercel AI Gateway, with a per-run `CLAUDE_CONFIG_DIR` so no user-level memory/plugins/hooks leak in, `--max-turns`, a wall-clock timeout, and the full `stream-json` transcript captured to `results/`.
3. **Grades** with deterministic checks: `zig build test` in the workspace, `zero-native markup check` on the `.zml` files, per-case file greps (e.g. "the board uses `<template>`"), and live automation-snapshot greps (build with `-Dautomation=true`, launch, `zero-native automate wait`, grep `snapshot.txt` for expected roles/names).
4. **Reports** a per-case `result.json` (pass/fail per check, durations, model, turns, cost) plus a console summary table.

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

Models are gateway slugs; the default is `anthropic/claude-sonnet-4.6` (override with `--model` or `ZN_EVAL_MODEL`).

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
pnpm eval --model anthropic/claude-opus-4.6 templates-settings-app
pnpm eval --skip-live                 # skip snapshot checks (no app launch / non-macOS)
pnpm eval --keep-workspaces           # keep .workspaces/<case> around for inspection
pnpm typecheck
```

Real runs exit non-zero if any case fails. Workspaces live in `.workspaces/` and results in `results/<timestamp>/<case>/` (`result.json`, `transcript.jsonl`, the isolated `claude-config/`); both directories are gitignored.

### Permissions for the agent-under-test

By default the agent runs with `--permission-mode acceptEdits` plus an allowlist covering `zig ...`, `zero-native ...`, and basic file commands — enough for unattended edit/build/test loops without granting arbitrary shell. `--skip-permissions` switches to `--dangerously-skip-permissions`; only use it if the default allowlist blocks a case, and remember the workspace is a throwaway dir but the process is not otherwise sandboxed.

## Cases

- `templates-settings-app` — validates the new grammar: repeated grouped toggle sections where `<template>`/`<use>` is the natural shape, plus token style attributes (muted headers, surface cards). Checks: build+tests, markup check, `<template>`/`<use>` greps, token-attribute greps, snapshot roles.
- `kanban-board` — port of the manual builder trial; card identity must survive moving between columns (`global-key`).
- `habits-tracker` — port of the manual markup trial; text entry (elm-style mirror), derived/filtered lists, enum filters.

Add a case by creating `cases/<name>/eval.json` (see `src/types.ts` for the schema). Prompts describe app **requirements**, never the solution — the point is to see whether a fresh agent reaches the intended grammar from the skill alone.

## CI

CI only typechecks the harness (`evals-typecheck` in `.github/workflows/ci.yml`). Eval runs are local/manual — no model calls in CI.
