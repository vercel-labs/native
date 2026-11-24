# Contributing

## Setup

```console
$ pnpm install
$ pnpm test                        # type-checks everything, builds the examples, checks flows and pixels
$ cd packages/cli
$ node compiler/cli.ts wpt fetch   # one-time: sparse WPT checkout into ~/.cache/native/wpt
```

The CLI and everything it compiles into an app live in `packages/cli`; the commands below run there. From the repository root, `pnpm typecheck`, `pnpm build`, `pnpm test`, `pnpm test:examples` and `pnpm wpt` run the same tasks through Turborepo.

[How it works](packages/cli/docs/how-it-works.md) explains the build-time/runtime split and where each area's code lives.

## Making a change

Work on a branch. For a change to HTML, CSS or DOM support:

1. Implement it the way the spec defines it. Unsupported features must keep producing a compiler warning, which is how `native check` and the WPT runner report them. Remove the warning only for what's now supported.
2. Prefer implementing features in runtime TypeScript over native host code. Keep `host/` thin.
3. Run the gates. `pnpm test` starts with `tsc`: Node strips types without checking them, so a type error in the compiler would otherwise only show up as broken generated code.
   ```console
   $ pnpm test
   $ node compiler/cli.ts wpt run
   $ node tests/wpt-regressions.ts origin/next wpt/results.json
   ```
   No test that passes on `next` may stop passing. `wpt show <test>` renders a test, its reference and their diff into one image when you need to see why it fails.
4. Update [supported features](packages/cli/docs/supported.md) (and its "Not yet supported" list).
5. Commit with a plain, descriptive message, and commit `wpt/results.json` with the change.

Never special-case WPT file names, loosen the pixel comparison or fuzzy rules, or count skips as passes. A feature only counts when it's implemented as CSS specifies.

## Rebasing

Rebase onto `origin/next` before asking for a merge. If `wpt/results.json` conflicts, take either side, then re-run `wpt run` and amend the commit with the regenerated file.

## Compiler bugs

If you hit a compiler bug or gap, reduce it to a minimal repro and open an issue, quoting the compiler's diagnostic code and the workaround you used. If the gap affects app code and has a workaround, add it to [known compiler limitations](packages/cli/docs/compiler-limitations.md).
