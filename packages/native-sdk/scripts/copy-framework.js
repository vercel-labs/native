#!/usr/bin/env node

// Mirror the SDK payload from the repo root into this package before
// packing (npm prepack). The published @native-sdk/cli carries everything
// an app build graph needs from its `native_sdk` path dependency: src/
// (the SDK modules), build/ + build.zig + build.zig.zon (the dependency's
// build script that `addApp` lives in), app.zon (the SDK's own manifest,
// which its build script reads at configure time), assets/ (files the
// build graph resolves from the dependency, e.g. the Windows application
// manifest build/app.zig wires via dep.path), third_party/webview2/ and
// third_party/sqlite/ (the vendored platform/storage sources build/app.zig
// resolves the same way; the CEF runtimes stay out — they are large
// downloaded artifacts, not repo files), and the agent skills. With the payload in
// the package, `native init && native dev` work offline right after
// install.
//
// packages/core/ ships too, selectively: TypeScript app cores need the
// @native-sdk/core frontend (src/, run under node at build time), the
// SDK library modules cores import (sdk/, also the editor package the CLI
// materializes into apps), the external-compile staging surface
// (compile-surface/ and the scripts/ drivers the build graph runs),
// package.json (the bundled version every scaffold pin follows), and
// package-lock.json (npm only strips the tarball ROOT lockfile; nested
// ones ship). The frontend's TypeScript toolchain and the external core
// compiler do NOT ride in the payload: the @typescript/old alias and
// scriptc are regular dependencies of @native-sdk/cli, installed by npm
// in the same transaction and resolved from packages/core by node's
// ancestor walk. test/ stays out: repo-dev surface, never build inputs.

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

{
  rmSync(join(projectRoot, 'third_party'), { recursive: true, force: true });
  for (const dir of ['webview2', 'sqlite']) {
    const source = join(repoRoot, 'third_party', dir);
    const target = join(projectRoot, 'third_party', dir);
    cpSync(source, target, { recursive: true });
    console.log(`✓ Copied third_party/${dir}/ to ${target}`);
  }
}

// corewire (tools/corewire): the contract-sidecar mirror/facade/profile
// generator every TypeScript-core build compiles from the dependency.
{
  const source = join(repoRoot, 'tools', 'corewire');
  const target = join(projectRoot, 'tools', 'corewire');
  rmSync(join(projectRoot, 'tools'), { recursive: true, force: true });
  cpSync(source, target, { recursive: true });
  console.log(`✓ Copied tools/corewire/ to ${target}`);
}

// The @native-sdk/core closure a TS app build needs (see the header note).
{
  rmSync(join(projectRoot, 'packages'), { recursive: true, force: true });
  for (const dir of ['src', 'sdk', 'compile-surface', 'scripts']) {
    const source = join(repoRoot, 'packages', 'core', dir);
    const target = join(projectRoot, 'packages', 'core', dir);
    cpSync(source, target, { recursive: true });
    console.log(`✓ Copied packages/core/${dir}/ to ${target}`);
  }
  for (const file of ['package.json', 'package-lock.json']) {
    const source = join(repoRoot, 'packages', 'core', file);
    const target = join(projectRoot, 'packages', 'core', file);
    copyFileSync(source, target);
    console.log(`✓ Copied packages/core/${file} to ${target}`);
  }
}

for (const file of ['build.zig', 'build.zig.zon', 'app.zon', 'LICENSE']) {
  const source = join(repoRoot, file);
  const target = join(projectRoot, file);
  rmSync(target, { force: true });
  copyFileSync(source, target);
  console.log(`✓ Copied ${file} to ${target}`);
}
