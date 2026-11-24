// pnpm restores packages from its content-addressable store with the modes they were published
// with, and npm normalizes the modes of files outside a package's `bin` entries: scriptc's native
// TypeScript server and LLVM codegen arrive without the executable bit, and the compiler then
// fails every build with "SC3004: TypeScript server startup: Permission denied". scriptc's own
// install script chmods them, but a pnpm install that takes the package from a cached store may
// skip that script, so the modes are set here too, from the toolchain manifests, on every install.
//
// Idempotent, silent about files that are not there (a platform package for another host, a
// partial install), and it never fails an install: the build itself reports a missing toolchain.

import { chmodSync, existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const fixed = [];

/** Sets a file executable (and searchable directories above it), and records what it touched. */
function makeExecutable(path) {
  try {
    if (!existsSync(path)) return;
    chmodSync(path, 0o755);
    fixed.push(path);
  } catch {
    // A read-only store or a platform where the mode does not apply is not this script's problem.
  }
}

/** A directory the tools are spawned from has to be searchable: a store that extracted it without
 *  the execute bit denies the exec even when the file itself is 0755. */
function makeSearchable(path) {
  try {
    if (existsSync(path)) chmodSync(path, 0o755);
  } catch {
    // As above.
  }
}

/**
 * The native packages of one `@scriptc/<kind>-…` family, wherever the install put them: beside
 * `node_modules/@scriptc` for npm and for a hoisted pnpm install, and under `.pnpm` for pnpm's
 * virtual store, which is where an optional dependency of scriptc lands.
 */
function nativePackages(root, kind) {
  const scope = "@scriptc";
  const out = [];
  const add = (full, name) => {
    if (!name.startsWith(kind + "-")) return;
    try {
      out.push(realpathSync(full));
    } catch {
      // a dangling link
    }
  };
  const scopes = [join(root, "node_modules", scope)];
  // A workspace package that depends on scriptc gets its own `node_modules/@scriptc` beside it.
  const workspace = join(root, "packages");
  if (existsSync(workspace)) {
    for (const pkg of readdirSync(workspace)) {
      const dir = join(workspace, pkg, "node_modules", scope);
      if (existsSync(dir)) scopes.push(dir);
    }
  }
  for (const direct of scopes) {
    if (!existsSync(direct)) continue;
    for (const name of readdirSync(direct)) add(join(direct, name), name);
  }
  const virtual = join(root, "node_modules", ".pnpm");
  if (existsSync(virtual)) {
    for (const dir of readdirSync(virtual)) {
      if (!dir.startsWith(scope.replace("/", "+") + "+" + kind + "-")) continue;
      const inside = join(virtual, dir, "node_modules", scope);
      if (!existsSync(inside)) continue;
      for (const name of readdirSync(inside)) add(join(inside, name), name);
    }
  }
  return out;
}

const root = resolve(process.argv[2] ?? ".");
// The CLI package is the one the compiler runs; its manifest names the TypeScript server binaries.
for (const pkg of nativePackages(root, "cli")) {
  makeExecutable(join(pkg, "dist/bin/scriptc"));
  const manifestPath = join(pkg, "dist/bin/scriptc.json");
  if (!existsSync(manifestPath)) continue;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch {
    continue;
  }
  makeSearchable(join(pkg, "dist/bin"));
  for (const key of ["ts7", "tsc_ts"]) {
    const rel = manifest[key];
    if (typeof rel !== "string" || rel === "") continue;
    const target = resolve(dirname(manifestPath), rel);
    makeSearchable(dirname(target));
    makeSearchable(dirname(dirname(target)));
    makeExecutable(target);
  }
  const llvm = manifest.llvm_package;
  if (typeof llvm === "string" && llvm !== "") {
    for (const name of ["scriptc-llvm-codegen", "scriptc-comptime"]) {
      makeExecutable(resolve(dirname(manifestPath), llvm, "bin", name));
    }
  }
}
// Every LLVM helper package, even one the manifest does not name (an older toolchain layout).
for (const pkg of nativePackages(root, "llvm")) {
  const bin = join(pkg, "bin");
  if (!existsSync(bin)) continue;
  makeSearchable(bin);
  for (const name of readdirSync(bin)) makeExecutable(join(bin, name));
}

if (fixed.length > 0 && process.env.NATIVE_FIX_MODES !== "0") {
  process.stderr.write(`native: set the executable bit on ${fixed.length} toolchain file(s)\n`);
}
