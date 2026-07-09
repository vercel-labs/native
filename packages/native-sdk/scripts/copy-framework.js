#!/usr/bin/env node

// Mirror the SDK payload from the repo root into this package before
// packing (npm prepack). The published @native-sdk/cli carries everything
// an app build graph needs from its `native_sdk` path dependency: src/
// (the SDK modules), build/ + build.zig + build.zig.zon (the dependency's
// build script that `addApp` lives in), app.zon (the SDK's own manifest,
// which its build script reads at configure time), assets/ (files the
// build graph resolves from the dependency, e.g. the Windows application
// manifest build/app.zig wires via dep.path), and the agent skills.
// With the payload in the package, `native init && native dev` work
// offline right after install.

import { cpSync, copyFileSync, rmSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

for (const dir of ['src', 'build', 'assets', 'skills', 'skill-data']) {
  const source = join(repoRoot, dir);
  const target = join(projectRoot, dir);
  rmSync(target, { recursive: true, force: true });
  cpSync(source, target, { recursive: true });
  console.log(`✓ Copied ${dir}/ to ${target}`);
}

for (const file of ['build.zig', 'build.zig.zon', 'app.zon', 'LICENSE']) {
  const source = join(repoRoot, file);
  const target = join(projectRoot, file);
  rmSync(target, { force: true });
  copyFileSync(source, target);
  console.log(`✓ Copied ${file} to ${target}`);
}
