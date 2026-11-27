# Contributing

## Setup

```console
$ pnpm install
$ pnpm test                        # type-checks everything, builds the examples, checks flows and pixels
$ cd packages/cli
$ node compiler/cli.ts wpt fetch   # one-time: sparse WPT checkout into ~/.cache/native/wpt
```

The repository is a pnpm workspace: the CLI and everything it compiles into an app live in `packages/cli`, the docs site in `apps/docs`, and each app under `examples/` is a package of its own. The commands below run in `packages/cli`, where a clone runs the CLI from source as `node compiler/cli.ts <command>` (from the repository root, `node packages/cli/compiler/cli.ts`); the examples' `native` is the same CLI. The web-platform tests build the headless Linux host and need the libraries listed in [cli.md](packages/cli/docs/cli.md). From the repository root, `pnpm typecheck`, `pnpm build`, `pnpm test`, `pnpm test:examples` and `pnpm wpt` run the same tasks through Turborepo.

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

## Node in development, scriptc for release

Develop with Node, compile with scriptc. Contributors run the CLI from source (`node compiler/cli.ts …`), with nothing to build first; the `@native-sdk/cli` package users install is the same code compiled by scriptc into a native executable, which needs no Node to run its commands. So `compiler/` and `shared/` stay one source tree that both run:

- Use what scriptc compiles. A Node-only API with no scriptc lowering (a loader hook, `node:vm`, `createRequire`, a recursive `fs.watch`) gets a small shim both paths use — `compiler/resolve.ts` resolves modules as Node does, `compiler/console-eval.ts` evaluates inspector console expressions, `compiler/watch-tree.ts` watches a tree a directory at a time — so a user sees the same behaviour from either.
- Find the CLI's own files through `ROOT` (`compiler/root.ts`), never `import.meta.url`: in the executable that is the path of the file on the machine that compiled it. The executable finds `runtime/`, `shared/` and `host/` from `NATIVE_SDK_ROOT` (the npm launcher sets it) or beside itself.
- A non-null assertion is checked at run time in the executable: `x!` on a null throws there, where Node carries on.

In the workspace, the examples' `native` command is still the CLI on Node (`dist/native.js`, which `pnpm build` bundles). Check a change against the executable as well when it touches the CLI, from `packages/cli`:

```console
$ pnpm build:native                                              # dist/native (dist/native.exe on Windows); add -- --dev to build faster
$ dist/native build ../../examples/counter -o build/counter
$ NATIVE_SDK_CLI=$PWD/dist/native node tests/examples.ts counter todo
$ pnpm pack:npm --check                                          # packs dist/npm and installs it into a new project
```

The published packages, which `scripts/pack.ts` lays out: `@native-sdk/cli` carries the launcher (`bin/native.js`), the `runtime/`, `shared/` and `host/` sources every app build compiles, and scriptc as a dependency; `@native-sdk/cli-<platform>` (darwin-arm64, darwin-x64, linux-x64, linux-arm64, win32-x64) carries the executable. The [cli workflow](.github/workflows/cli.yml) builds every platform's executable and runs the examples gate with it on Linux and Windows; [release.yml](.github/workflows/release.yml) (a `v*` tag) and [prerelease.yml](.github/workflows/prerelease.yml) (manual) publish them.

## Rebasing

Rebase onto `origin/next` before asking for a merge. If `wpt/results.json` conflicts, take either side, then re-run `wpt run` and amend the commit with the regenerated file.

## Compiler bugs

If you hit a compiler bug or gap, reduce it to a minimal repro and open an issue, quoting the compiler's diagnostic code and the workaround you used. If the gap affects app code and has a workaround, add it to [known compiler limitations](packages/cli/docs/compiler-limitations.md).
