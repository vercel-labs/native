// SDK library modules (sdk/*.ts besides the intrinsic sdk/core.ts) are
// ordinary app-core subset TypeScript that transpiles INTO a core when
// imported. This is their validate-once gate: every module must transpile
// standalone — tsc-clean, subset-clean, and emitted — so an app build can
// never be the first place an SDK module meets the checker. App builds
// still re-check them (the re-check is nearly free: tsc parses the file
// for the program anyway), so a diagnostic pointing into sdk/ is an SDK
// bug by construction, caught here first.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { transpileFile } from "../src/transpile.ts";
import { sdkLibraryModules } from "../src/typed_ast.ts";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const sdkDir = path.join(pkg, "sdk");

test("every shipped SDK library module is registered", () => {
  const shipped = fs
    .readdirSync(sdkDir)
    // .d.ts files are ambient type surface (bytes_text_methods.d.ts joins
    // every core's program as a root), never importable library modules.
    .filter((f) => f.endsWith(".ts") && !f.endsWith(".d.ts") && f !== "core.ts")
    .map((f) => path.join(sdkDir, f))
    .sort();
  const registered = [...sdkLibraryModules.values()].map((p) => path.resolve(p)).sort();
  assert.deepEqual(shipped, registered, "sdk/*.ts and sdkLibraryModules must agree");
});

test("every SDK library module transpiles standalone (tsc-clean, subset-clean, emitted)", () => {
  for (const [name, file] of sdkLibraryModules) {
    const result = transpileFile(file);
    assert.equal(result.typeErrors.length, 0, `${name}: tsc errors\n${result.typeErrors.join("\n")}`);
    const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
    assert.equal(result.ok, true, `${name}: transpile failed\n${details}`);
    assert.equal(result.warnings.length, 0, `${name}: unexpected warnings`);
  }
});
