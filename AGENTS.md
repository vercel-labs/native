# Agent Guide

Guidance for agents (and humans) working on this repository.

## App authoring default

Native SDK itself is implemented in Zig, but Native SDK **apps are authored in TypeScript + Native markup by default**. Do not infer the app-authoring language from this repository's implementation language or from older Zig-core examples.

- For a new app, use `native init <path>` and expect `src/core.ts`, `src/app.native`, and `app.zon`. Ordinary compiled TypeScript work that needs filesystem, process, JSON, regex, classes, or other static-tier APIs belongs under optional `src/services/`, reached from the core with `Cmd.request`; do not import a service from the core. Do not add Zig app code unless the user explicitly chooses `--template zig-core` or the feature requires a toolkit extension.
- Before changing an existing app, inspect its tree. A `src/core.ts` app stays TypeScript; a `src/main.zig` app stays Zig unless the task is specifically a migration.
- For default app work, read `skill-data/native-ui/SKILL.md` and `skill-data/ts-core/SKILL.md`; also read `skill-data/ts-services/SKILL.md` when the tree has `src/services/` or the task needs ordinary TypeScript beyond the core subset. `skill-data/core/SKILL.md` covers shared/runtime concerns; `skill-data/zig/SKILL.md` is for Zig-core apps and SDK implementation work.
- The `-ts` suffix on a few examples only distinguishes ports from older Zig originals. New TypeScript apps need no suffix because TypeScript is the default.

## Build, test, and gate

```bash
zig build test                # root engine + runtime suites
zig build validate            # sample app.zon manifest check
zig build test-example-<name> # one example's suite (e.g. test-example-notes)
scripts/gate.sh fast [ref]    # affected-only local gate for your diff (default base: main)
scripts/gate.sh full          # everything CI-shaped that runs locally
```

Run `scripts/gate.sh fast` before finishing any change; it maps your diff to the suites that cover it. The docs site checks with `pnpm --dir docs check` (the gate runs it only when `docs/` changed).

This repository builds with Zig 0.16.0. If a build fails with "no member named" errors on std APIs (`std.fs.cwd`, `ArrayList.init`, `std.io`), you are writing pre-0.16 idioms — `skill-data/zig/SKILL.md` maps each such compile error to the current idiom as this codebase writes it.

Pinned goldens (pixel signatures, schema fingerprints, command counts) are updated deliberately: review the rendered output or the counted commands first, and keep the pin's comment a self-contained description of what the value represents.

## Changelog

Do not edit `CHANGELOG.md` as part of regular feature or fix work. The release agent reviews the git history since the previous release and writes the complete changelog entry during release preparation; see [RELEASING.md](./RELEASING.md).

## Where things live

- `src/` — the engine and runtime; `src/primitives/canvas/` holds the widget, markup, and vector core.
- `examples/` — the showcase apps, most zero-config (`app.zon` + `src/`).
- `docs/` — the documentation site; `docs/AGENTS.md` has its MDX conventions.
- `skills/` and `skill-data/` — the agent skills the CLI ships (`native skills list`).
- `tools/` and `scripts/` — dev tooling and the local gate.

Releases are maintainer-run; see [RELEASING.md](./RELEASING.md).
