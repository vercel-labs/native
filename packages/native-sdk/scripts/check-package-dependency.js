#!/usr/bin/env node

// Verify the packed @native-sdk/cli works as a Zig path dependency. Packs
// this package (prepack mirrors the SDK payload first), extracts the
// tarball into a fresh Zig project that declares
// `.native_sdk = .{ .path = "package" }`, and runs `zig build --help`
// there. That compiles the package's build.zig and runs its `build()`, so
// any file the build graph reads at compile or configure time but the
// package "files" list leaves out fails this check. Set ZIG to choose the
// zig executable (default: zig on PATH).

import { spawnSync } from 'child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const zig = process.env.ZIG || 'zig';

const buildZigZon = `.{
    .name = .package_check,
    .version = "0.0.0",
    .fingerprint = 0xa98aabf4fdf01038,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .native_sdk = .{ .path = "package" },
    },
    .paths = .{""},
}
`;

const buildZig = `const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.dependency("native_sdk", .{});
}
`;

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf-8',
    shell: process.platform === 'win32' && command === 'npm',
  });
  if (result.error) return { status: 1, stdout: '', stderr: `${command}: ${result.error.message}` };
  return result;
}

// Returns null on success, or the failure output.
function check(work) {
  const pack = run('npm', ['pack', '--json', '--pack-destination', work], projectRoot);
  if (pack.status !== 0) return `${pack.stdout}${pack.stderr}\nnpm pack failed`;
  const [{ filename }] = JSON.parse(pack.stdout.slice(pack.stdout.indexOf('[')));

  const app = join(work, 'app');
  mkdirSync(app);
  const untar = run('tar', ['-xzf', join(work, filename), '-C', app], work);
  if (untar.status !== 0) return `${untar.stderr}\ncannot extract ${filename}`;
  writeFileSync(join(app, 'build.zig.zon'), buildZigZon);
  writeFileSync(join(app, 'build.zig'), buildZig);

  const help = run(zig, ['build', '--help'], app);
  if (help.status !== 0) return `${help.stderr}\nzig build --help failed in a project that depends on ${filename}`;
  console.log(`✓ ${filename} works as a Zig path dependency (zig build --help)`);
  return null;
}

const work = mkdtempSync(join(tmpdir(), 'native-sdk-package-check-'));
let failure;
try {
  failure = check(work);
} finally {
  rmSync(work, { recursive: true, force: true });
}
if (failure) {
  console.error(failure);
  process.exit(1);
}
