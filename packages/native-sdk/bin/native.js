#!/usr/bin/env node

// Dispatcher for the `native` CLI: finds the prebuilt binary for this
// platform and execs it. The binary ships in a per-platform package
// (@native-sdk/cli-<platform>, an optionalDependency of this package),
// so npm downloads exactly one Native SDK binary. The package install
// script separately prepares the checksum-verified scriptc toolchain.
//
// The SDK source an app builds against ships in THIS package (src/,
// build/, build.zig) — the dispatcher passes its location down via
// NATIVE_SDK_PATH so `native init && native dev` work offline, and the
// binary itself can also derive the location from its own path when
// invoked directly.

import { spawn, execSync } from 'child_process';
import { existsSync, accessSync, chmodSync, constants } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
import { platform, arch } from 'os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(__dirname, '..');
const require = createRequire(import.meta.url);

function isMusl() {
  if (platform() !== 'linux') return false;
  try {
    const result = execSync('ldd --version 2>&1 || true', { encoding: 'utf8' });
    return result.toLowerCase().includes('musl');
  } catch {
    return existsSync('/lib/ld-musl-x86_64.so.1') || existsSync('/lib/ld-musl-aarch64.so.1');
  }
}

// -> { pkg: "@native-sdk/cli-<platform>", legacy: "native-sdk-<platform>[.exe]" }
// legacy is the flat bin/ name used by scripts/copy-native.js for repo-local
// development packs.
function platformTarget() {
  const os = platform();
  const cpuArch = arch();

  let archKey;
  switch (cpuArch) {
    case 'x64':
    case 'x86_64': archKey = 'x64'; break;
    case 'arm64':
    case 'aarch64': archKey = 'arm64'; break;
    default: return null;
  }

  switch (os) {
    case 'darwin':
      return { pkg: `@native-sdk/cli-darwin-${archKey}`, legacy: `native-sdk-darwin-${archKey}`, exe: '' };
    case 'linux': {
      const libc = isMusl() ? 'musl' : 'gnu';
      const legacyOs = isMusl() ? 'linux-musl' : 'linux';
      return { pkg: `@native-sdk/cli-linux-${archKey}-${libc}`, legacy: `native-sdk-${legacyOs}-${archKey}`, exe: '' };
    }
    case 'win32':
      return { pkg: `@native-sdk/cli-win32-${archKey}`, legacy: `native-sdk-win32-${archKey}.exe`, exe: '.exe' };
    default:
      return null;
  }
}

function resolveBinary(target) {
  // 1. The per-platform package (normal install: nested under this
  //    package, hoisted, or a sibling global install).
  try {
    return require.resolve(`${target.pkg}/bin/native${target.exe}`);
  } catch {}

  // 2. A binary placed directly in this package's bin/ (repo-local
  //    development via scripts/copy-native.js).
  const legacyPath = join(__dirname, target.legacy);
  if (existsSync(legacyPath)) return legacyPath;

  return null;
}

function main() {
  const target = platformTarget();

  if (!target) {
    console.error(`Error: Unsupported platform: ${platform()}-${arch()}`);
    process.exit(1);
  }

  const binaryPath = resolveBinary(target);

  if (!binaryPath) {
    console.error(`Error: No native binary found for ${platform()}-${arch()}.`);
    console.error(`Expected package: ${target.pkg}`);
    console.error('');
    console.error('This usually means install ran with --no-optional or --omit=optional.');
    console.error('Reinstall with optional dependencies enabled:');
    console.error('  npm install -g @native-sdk/cli');
    process.exit(1);
  }

  if (platform() !== 'win32') {
    try {
      accessSync(binaryPath, constants.X_OK);
    } catch {
      try {
        chmodSync(binaryPath, 0o755);
      } catch (chmodErr) {
        console.error(`Error: Cannot make binary executable: ${chmodErr.message}`);
        console.error('Try running: chmod +x ' + binaryPath);
        process.exit(1);
      }
    }
  }

  // Tell the binary where the SDK source lives (this package). An explicit
  // NATIVE_SDK_PATH from the user always wins; the fallback is only set
  // when this package actually carries the SDK payload.
  const env = { ...process.env };
  if (!env.NATIVE_SDK_PATH && existsSync(join(packageRoot, 'src', 'root.zig'))) {
    env.NATIVE_SDK_PATH = packageRoot;
  }

  const child = spawn(binaryPath, process.argv.slice(2), {
    stdio: 'inherit',
    windowsHide: false,
    env,
  });

  // Forward termination signals so killing this wrapper also stops the
  // CLI (and the process tree it owns — `native dev` runs the app).
  // Ctrl-C already reaches the child through the shared terminal group;
  // this covers a plain `kill <wrapper pid>`.
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => {
      child.kill(signal);
    });
  }

  child.on('error', (err) => {
    console.error(`Error executing binary: ${err.message}`);
    process.exit(1);
  });

  child.on('close', (code, signal) => {
    if (signal) {
      // Re-raise the child's fatal signal with default disposition so the
      // caller sees the same termination (conventional 128+N exit).
      process.removeAllListeners(signal);
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code ?? 0);
  });
}

main();
