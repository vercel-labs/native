// Integration gate: transpile the fixture core, build against the rt kernel,
// replay the deterministic 1k-message run, require the oracle digest.
// Skipped when no zig toolchain is on PATH (the unit suites still run).

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;

test("run1k digest matches the hand-written oracle", { skip: !hasZig, timeout: 300_000 }, () => {
  const out = execFileSync(process.execPath, [path.join(pkg, "scripts/gate.mjs"), "--skip-bench"], {
    encoding: "utf8",
  });
  assert.match(out, /run1k digest matches oracle/);
  assert.match(out, /PASS/);
});
