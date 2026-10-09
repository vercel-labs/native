import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { invocationCases } from "./invocation_cases.ts";
import { invoke } from "./invocation_fixture.ts";
assert.ok(process.argv[2], "run with the compiled corewire path (zig build test-corewire-policy)");
const corewire = path.resolve(process.argv[2]);
// Captured from the independent native coordinator, before this migration.
// Mirror hashes include the reviewed stateless-runtime API addition.
// Facade hashes include exact u32 image identities, nonreplacing file
// results and exact-range timers. Removing the reviewed timer encoder
// addition recovers every previous complete facade pin. The byte-key
// encoder and bounded 4 MiB view changes are also audited against those
// complete pins; their removal recovers the earlier generator output.
const goldens = JSON.parse(fs.readFileSync(new URL("invocation_goldens.json", import.meta.url), "utf8"));
for (const item of invocationCases()) test("invocation: " + item.name, () => {
  assert.ok(goldens[item.name], "missing independent native reference");
  assert.deepEqual(invoke(corewire, item), goldens[item.name]);
});
