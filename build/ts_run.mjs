#!/usr/bin/env node

// Run a TypeScript module of the @native-sdk/core transpiler tier under
// node from ANY SDK layout:
//
//   node ts_run.mjs <module.ts> [args...]
//
// From a repo checkout `node packages/core/src/cli.ts` works directly —
// node strips types natively. From the npm-installed @native-sdk/cli the
// SAME file sits inside node_modules, where node refuses its builtin type
// stripping by design (ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING). This
// runner closes that gap without forking the layouts: it registers a load
// hook that strips ONLY node_modules-resident .ts modules, using the
// transpiler's own TypeScript toolchain (shipped as a dependency of
// @native-sdk/cli, or a repo checkout's `npm ci` install inside
// packages/core — either way resolved from the target module's location
// by node's ancestor node_modules walk), and leaves
// every other module to node's native handling. Then it imports the
// requested module with argv respliced so the target sees its usual shape
// (its own path at argv[1], its arguments from argv[2]).
//
// On node builds without module.registerHooks (< 22.15) the hook is
// skipped: repo checkouts keep working natively and the npm layout fails
// with node's own teaching error naming the unsupported stripping.

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

if (typeof module.registerHooks === 'function') {
  let ts = null;
  module.registerHooks({
    load(url, context, nextLoad) {
      if (url.startsWith('file:') && url.endsWith('.ts') && url.includes('node_modules')) {
        const filePath = fileURLToPath(url);
        // The transpiler's own dependency, resolved from the transpiler's
        // location (packages/core/node_modules after the taught `npm ci`).
        ts ??= createRequire(targetPath)('@typescript/typescript6');
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
