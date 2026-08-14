// The publish contract of @native-sdk/core, pinned. The npm package is the
// EDITOR-AND-VERSIONING surface of the TypeScript tier: an app's
// node_modules copy (materialized by the `native` CLI before the package is
// published, overwritten byte-for-byte by `npm install` after) exists so
// stock editor TypeScript resolves `@native-sdk/core` — builds never read
// it. That contract only holds while this manifest keeps its shape:
//
//   - the artifact is package.json + sdk/ + compile-surface/ and nothing
//     else (`files`), so the CLI's pre-publish copy and the published
//     tarball stay identical (compile-surface/ is the external-compile
//     stage's static restatement of the SDK module; sdk/*.d.ts are the
//     generated declaration twins external tooling resolves);
//   - the exports map resolves ".", "./text", and "./events" to the shipped
//     TS sources,
//     with a `types` condition, so tsc's bundler resolution types both;
//   - exactly one runtime dependency — the external core compiler,
//     exact-pinned (this manifest is the ONE place the pin lives) — and
//     no bin: every TypeScript-core build resolves the compiler from
//     this package's own node_modules, and the frontend (checker +
//     contract) still runs from the SDK checkout with its dev install.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const manifest = JSON.parse(fs.readFileSync(path.join(pkg, "package.json"), "utf8"));
const cliManifest = JSON.parse(fs.readFileSync(path.join(pkg, "..", "native-sdk", "package.json"), "utf8"));

test("the manifest names the published package and a real version", () => {
  assert.equal(manifest.name, "@native-sdk/core");
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
  assert.equal(manifest.type, "module");
});

test("provenance metadata names the real repository", () => {
  // npm publish --provenance validates repository.url against the
  // publishing workflow's repository and rejects the tarball on any
  // mismatch — a publish-blocking field, not decoration.
  assert.equal(manifest.repository?.type, "git");
  assert.equal(manifest.repository?.url, "git+https://github.com/vercel-labs/native.git");
  assert.equal(manifest.repository?.directory, "packages/core");
  assert.equal(manifest.homepage, "https://native-sdk.dev");
});

test("the artifact is exactly package.json + sdk/ + compile-surface/", () => {
  assert.deepEqual(manifest.files, ["sdk", "compile-surface"]);
  // A bin entry would drag its target file into the tarball behind the
  // `files` allowlist and break the copy-equals-publish contract.
  assert.equal(manifest.bin, undefined);
  // The external-compile stage's one static SDK surface.
  assert.ok(fs.existsSync(path.join(pkg, "compile-surface", "core.ts")));
  // The generated declaration twins ship beside the sources.
  for (const name of ["core.d.ts", "text.d.ts", "events.d.ts"]) {
    assert.ok(fs.existsSync(path.join(pkg, "sdk", name)), `sdk/${name} does not exist`);
  }
});

test("exports resolve ., ./text, and ./events to shipped sources, types included", () => {
  const entries = Object.entries(manifest.exports);
  assert.deepEqual(entries.map(([key]) => key), [".", "./text", "./events"]);
  for (const [, target] of entries) {
    assert.equal(typeof target.types, "string");
    assert.equal(target.types, target.default);
    // Every export target must ship (live inside a `files` directory).
    assert.ok(target.types.startsWith("./sdk/"), `${target.types} is outside sdk/`);
    assert.ok(fs.existsSync(path.join(pkg, target.types)), `${target.types} does not exist`);
  }
  assert.equal(manifest.exports["."].types, "./sdk/core.ts");
  assert.equal(manifest.exports["./text"].types, "./sdk/text.ts");
  assert.equal(manifest.exports["./events"].types, "./sdk/events.ts");
  assert.equal(manifest.types, "./sdk/core.ts");
});

test("the one runtime dependency is the exact-pinned external core compiler", () => {
  // One dependency, exact-pinned: every TypeScript-core build resolves
  // the compiler from this package's own node_modules, and an exact pin
  // is what makes the profile's release-pinned fence table trustworthy
  // (this manifest is the one place the pin lives). No bin joins it —
  // installing the package must never put a toolchain on a consumer's
  // PATH.
  const pin = manifest.dependencies?.scriptc;
  assert.match(pin, /^\d+\.\d+\.\d+$/);
  assert.deepEqual(manifest.dependencies, { scriptc: pin });
  assert.equal(cliManifest.dependencies?.scriptc, pin, "the published CLI and @native-sdk/core must ship one compiler release");
});
