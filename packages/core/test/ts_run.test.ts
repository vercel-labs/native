// The layout-neutral runner (build/ts_run.mjs) under both node capability
// tiers. Node 24 is the common floor because scriptc 0.0.33's published
// bootstrap uses Node 24's compile cache; module.registerHooks then strips
// the runner strips EVERY .ts target with the transpiler's own toolchain
// — node's native stripping is never relied on (it refuses node_modules
// by design). On a hooks-less Node 24 build ANY .ts target must fail fast
// with the one-line branch-aware teaching instead of node's raw
// extension/stripping error — checkout-resident targets included, because
// the shared runner requires its load hook.
//
// The hooks-less tier is simulated by deleting module.registerHooks in a
// --import preload before the runner loads — the spawned node then presents
// exactly the capability surface the runner's check reads, with no
// test-only seam inside ts_run.mjs itself.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const runner = path.join(path.dirname(path.dirname(pkg)), "build", "ts_run.mjs");

// Pins the teaching verbatim: the string the runner prints on a node
// without registerHooks. Layout-neutral on purpose: checkouts hit this
// teaching exactly like npm installs do.
const teaching = "TypeScript apps need Node.js 24+";

// A module whose types only stripping (the runner's hook) can remove.
const typedModule = 'const answer: number = 42;\nconsole.log("RAN", answer);\n';

function withFixture<T>(root: string, targetRel: string, run: (target: string) => T): T {
  const dir = fs.mkdtempSync(root);
  try {
    const target = path.join(dir, targetRel);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, typedModule);
    return run(target);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function runRunner(target: string, { withoutHooks = false } = {}) {
  const args: string[] = [];
  if (withoutHooks) {
    const stub = path.join(path.dirname(target), "no_hooks.mjs");
    fs.writeFileSync(stub, 'import module from "node:module";\ndelete module.registerHooks;\n');
    args.push("--import", pathToFileURL(stub).href);
  }
  args.push(runner, target);
  return spawnSync(process.execPath, args, { encoding: "utf8" });
}

test("without registerHooks, a node_modules-resident target is taught Node 24 before import", () => {
  withFixture(path.join(os.tmpdir(), "tsrun-npm-"), path.join("node_modules", "app", "core.ts"), (target) => {
    const result = runRunner(target, { withoutHooks: true });
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.includes(teaching), `expected the teaching, got:\n${result.stderr}`);
    assert.ok(result.stderr.includes(process.version));
    assert.ok(!result.stdout.includes("RAN"), "the target must not be imported");
  });
});

test("without registerHooks, a repo-checkout target is taught Node 24 too", () => {
  // Hooks-absent teaches for every .ts target, keeping the Node 24 floor
  // honest for both layouts.
  withFixture(path.join(os.tmpdir(), "tsrun-checkout-"), path.join("app", "core.ts"), (target) => {
    const result = runRunner(target, { withoutHooks: true });
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.includes(teaching), `expected the teaching, got:\n${result.stderr}`);
    assert.ok(result.stderr.includes(process.version));
    assert.ok(!result.stdout.includes("RAN"), "the target must not be imported");
  });
});

test("with registerHooks, a node_modules-resident target is stripped and runs", () => {
  // The fixture lives under packages/core so the hook's ancestor
  // node_modules walk from the target resolves this package's own
  // @typescript/old dev install — the npm layout in miniature.
  withFixture(path.join(pkg, ".tsrun-fixture-"), path.join("node_modules", "app", "core.ts"), (target) => {
    const result = runRunner(target);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes("RAN 42"));
    assert.ok(!result.stderr.includes(teaching));
  });
});

test("with registerHooks, a repo-checkout target is stripped by the hook and runs", () => {
  // Checkout-resident modules go through the SAME hook (one code path):
  // the hook short-circuits before native stripping would apply.
  withFixture(path.join(pkg, ".tsrun-fixture-"), path.join("app", "core.ts"), (target) => {
    const result = runRunner(target);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes("RAN 42"));
    assert.ok(!result.stderr.includes(teaching));
  });
});

test("with registerHooks but no resolvable toolchain, a direct run gets the toolchain teaching", () => {
  // A direct `node ts_run.mjs` against a target with no @typescript/old
  // anywhere on its ancestor walk (the CLI verbs gate this earlier, with
  // fuller per-layout teachings): the hook must fail with the one-line
  // toolchain teaching, never a raw MODULE_NOT_FOUND stack.
  withFixture(path.join(os.tmpdir(), "tsrun-notc-"), path.join("app", "core.ts"), (target) => {
    const result = runRunner(target);
    assert.notEqual(result.status, 0);
    assert.ok(
      result.stderr.includes("@typescript/old") && result.stderr.includes("npm ci --include=dev"),
      `expected the toolchain teaching, got:\n${result.stderr}`,
    );
    assert.ok(!result.stdout.includes("RAN"), "the target must not run");
  });
});
