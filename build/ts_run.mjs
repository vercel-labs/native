#!/usr/bin/env node

// Run a TypeScript module of the @native-sdk/core transpiler tier under
// node from ANY SDK layout:
//
//   node ts_run.mjs <module.ts> [args...]
//
// ONE code path for every layout: a load hook strips EVERY .ts module with
// the transpiler's own pinned TypeScript compiler (shipped as a dependency
// of @native-sdk/cli, or a repo checkout's `npm ci` install inside
// packages/core — either way resolved from the target module's location by
// node's ancestor node_modules walk). Node's own type stripping is never
// relied on: it refuses node_modules-resident .ts by design
// (ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING), and outside node_modules
// it only became DEFAULT in node 22.18 — so a checkout target on
// 22.15-22.17 would die with ERR_UNKNOWN_FILE_EXTENSION if the hook let it
// "fall through". Hooking everything makes the 22.15 floor true for both
// layouts. Then the runner imports the requested module with argv
// respliced so the target sees its usual shape (its own path at argv[1],
// its arguments from argv[2]).
//
// On node builds without module.registerHooks (pre-22.15, or 23.0-23.4 —
// the hook landed in 22.15 and 23.5, so ">=22.15" alone is not the
// capability line) NO .ts target can run — node_modules-resident
// stripping is refused by design and default stripping outside
// node_modules only landed in 22.18, which is above this tier anyway —
// so the runner fails fast with one teaching line (upgrade to Node.js
// 22.15+, on the 23 line 23.5+) before importing it, instead of
// surfacing node's raw extension/stripping error.

import module, { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const target = process.argv[2];
if (!target) {
  console.error('usage: node ts_run.mjs <module.ts> [args...]');
  process.exit(2);
}
const targetPath = resolve(target);
// Drop the runner from argv so the target module parses its own argv
// exactly as when node runs it directly.
process.argv.splice(1, 1);

if (typeof module.registerHooks !== 'function') {
  // No load hooks on this node (pre-22.15, or a 23.0-23.4 build). Every
  // .ts target needs the hook — node_modules-resident stripping is
  // refused by design, and native default stripping outside node_modules
  // is 22.18+ — so any .ts target would fail deep inside node with a raw
  // extension/stripping error. Teach the fix instead.
  if (targetPath.endsWith('.ts')) {
    console.error(
      `TypeScript apps need Node.js 22.15+ (on the 23 line: 23.5+); you're running ${process.version} - upgrade node and re-run.`,
    );
    process.exit(1);
  }
} else {
  let ts = null;
  module.registerHooks({
    load(url, context, nextLoad) {
      if (url.startsWith('file:') && url.endsWith('.ts')) {
        const filePath = fileURLToPath(url);
        // The transpiler's own pinned compiler, resolved from the target
        // module's location (packages/core/node_modules after the taught
        // `npm ci`, or the dependency npm installed beside the CLI). The
        // ALIAS is required directly — not the @typescript/typescript6
        // wrapper — because the wrapper's re-export resolves
        // "@typescript/old" from the WRAPPER's own location, where a
        // consumer tree's conflicting hoisted copy would win nearest-wins
        // over our exact pin; resolving from the target finds our own
        // nested/hoisted pin first (same reasoning as typed_ast.ts).
        if (ts === null) {
          try {
            ts = createRequire(targetPath)('@typescript/old');
          } catch {
            // A missing toolchain reaches here only on a direct
            // `node ts_run.mjs` run: every CLI verb gates resolution with
            // a fuller per-layout teaching before this runner is spawned.
            // Keep the direct-run error sane and name the checkout fix.
            console.error(
              `ts_run.mjs: the transpiler's TypeScript toolchain (@typescript/old) does not resolve from ${targetPath} - on a repo checkout, run \`npm ci --include=dev\` in packages/core.`,
            );
            process.exit(1);
          }
        }
        const { outputText } = ts.transpileModule(readFileSync(filePath, 'utf8'), {
          fileName: filePath,
          compilerOptions: {
            target: ts.ScriptTarget.ESNext,
            module: ts.ModuleKind.ESNext,
            verbatimModuleSyntax: true,
          },
        });
        return { format: 'module', source: outputText, shortCircuit: true };
      }
      return nextLoad(url, context);
    },
  });
}

await import(pathToFileURL(targetPath).href);
