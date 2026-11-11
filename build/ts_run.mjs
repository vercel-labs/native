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
// it only became DEFAULT in node 22.18. Hooking everything keeps both layouts
// identical. The TypeScript frontend uses Node 24's synchronous load hooks,
// so this shared runner enforces that floor before importing any frontend
// module. Then it imports the requested module with argv
// respliced so the target sees its usual shape (its own path at argv[1],
// its arguments from argv[2]).
//
// A Node 24 build without module.registerHooks is incomplete for this tier,
// so the runner gives the same Node 24 teaching instead of surfacing a raw
// extension/stripping error.

import module from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { registerTsModules } from '../packages/core/scripts/ts_modules.mjs';

const target = process.argv[2];
if (!target) {
  console.error('usage: node ts_run.mjs <module.ts> [args...]');
  process.exit(2);
}
const targetPath = resolve(target);
const nodeMajor = Number(process.versions.node.split('.')[0]);
if (!Number.isInteger(nodeMajor) || nodeMajor < 24) {
  console.error(`TypeScript apps need Node.js 24+; you're running ${process.version} - upgrade node and re-run.`);
  process.exit(1);
}
// Drop the runner from argv so the target module parses its own argv
// exactly as when node runs it directly.
process.argv.splice(1, 1);

if (typeof module.registerHooks !== 'function') {
  // Every .ts target needs the hook. A supported Node build without it is
  // incomplete for this tier, so teach the supported installation instead.
  if (targetPath.endsWith('.ts')) {
    console.error(
      `TypeScript apps need Node.js 24+ with module.registerHooks; you're running ${process.version} - upgrade or reinstall node and re-run.`,
    );
    process.exit(1);
  }
} else {
  // The shared hook resolves the frontend's own pinned compiler from the
  // target module's location (packages/core/node_modules after the taught
  // `npm ci`, or the dependency npm installed beside the CLI). Resolving
  // from the target finds our own nested/hoisted exact pin first, so a
  // consumer tree's conflicting hoisted typescript never wins nearest-wins
  // over it (same reasoning as typed_ast.ts). Every script that imports the
  // transpiler tier — including the external-compile staging script — uses
  // this same hook.
  registerTsModules(targetPath);
}

await import(pathToFileURL(targetPath).href);
