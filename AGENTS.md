# Agent Guide

Guidance for agents (and humans) working on this repository.

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

## Design guide

Read and follow [DESIGN.md](./DESIGN.md) before changing built-in UI, examples, templates, component previews, or Native UI docs. New UI should use the framework's native widgets first, keep visual identity token-driven, and verify accessibility, keyboard behavior, and layout stability. Call out any deliberate divergence in the change summary.

## Changelog

Do not edit `CHANGELOG.md` directly. Each user-visible change ships a fragment in `changelog.d/` — see `changelog.d/README.md` for the format and voice. Internal-only polish needs no fragment.

## Where things live

- `src/` — the engine and runtime; `src/primitives/canvas/` holds the widget, markup, and vector core.
- `examples/` — the showcase apps, most zero-config (`app.zon` + `src/`).
- `docs/` — the documentation site; `docs/AGENTS.md` has its MDX conventions.
- `skills/` and `skill-data/` — the agent skills the CLI ships (`native skills list`).
- `tools/` and `scripts/` — dev tooling and the local gate.

Releases are maintainer-run; see [RELEASING.md](./RELEASING.md).
