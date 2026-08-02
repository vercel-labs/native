// The publish contract of @native-sdk/core, pinned. The npm package is the
// EDITOR-AND-VERSIONING surface of the TypeScript tier: an app's
// node_modules copy (materialized by the `native` CLI before the package is
// published, overwritten byte-for-byte by `npm install` after) exists so
// stock editor TypeScript resolves `@native-sdk/core` — builds never read
// it. That contract only holds while this manifest keeps its shape:
//
//   - the artifact is package.json + sdk/ and nothing else (`files`), so
//     the CLI's pre-publish copy and the published tarball stay identical;
//   - the exports map resolves ".", "./text", and "./events" to the shipped
//     TS sources,
//     with a `types` condition, so tsc's bundler resolution types both;
//   - no runtime dependencies and no bin: installing the package into an
//     app must add types, not a toolchain (the transpiler runs from the
//     SDK checkout with its own dev install).

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const manifest = JSON.parse(fs.readFileSync(path.join(pkg, "package.json"), "utf8"));

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

test("the artifact is exactly package.json + sdk/", () => {
  assert.deepEqual(manifest.files, ["sdk"]);
  // A bin entry would drag its target file into the tarball behind the
  // `files` allowlist and break the copy-equals-publish contract.
  assert.equal(manifest.bin, undefined);
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

test("installing the package adds types, never a toolchain", () => {
  assert.equal(manifest.dependencies, undefined);
});
