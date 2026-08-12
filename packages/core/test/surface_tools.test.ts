// The compile-surface tooling, held to its contract: the manifest diff
// categorizes every change class by stable id (flips to static carry
// their retirement call-outs; regressions never masquerade as
// easings), and the generated service-surface reference stays
// byte-derived from the pinned compiler manifest — the check that the
// gate runs must pass on the committed tree, or capability claims are
// drifting from the compiler again.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const diffScript = path.join(pkg, "scripts", "surface_manifest_diff.mjs");
const genScript = path.join(pkg, "scripts", "gen_service_surface.mjs");

function writeManifest(dir: string, name: string, version: string, entries: unknown[]): string {
  const file = path.join(dir, name);
  fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, compilerVersion: version, coverage: [], entries }));
  return file;
}

test("surface_manifest_diff categorizes every change class by stable id", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "surface-diff-"));
  const oldManifest = writeManifest(dir, "old.json", "0.0.1", [
    { id: "diagnostic.sc1070", kind: "diagnostic-fence", name: "async/await", status: "unsupported", code: "SC1070" },
    { id: "stdlib.math.abs", kind: "stdlib", name: "Math.abs", status: "static" },
    { id: "stdlib.date.now", kind: "stdlib", name: "Date.now", status: "static", note: "the live clock" },
    { id: "syntax.namespaces", kind: "syntax", name: "namespaces", status: "unsupported", code: "SC1090" },
    { id: "node-builtin.tty", kind: "node-builtin", name: "tty", status: "static" },
  ]);
  const newManifest = writeManifest(dir, "new.json", "0.0.2", [
    // flipped to static, and a watched id: the diff must call out the retirement
    { id: "diagnostic.sc1070", kind: "diagnostic-fence", name: "async/await", status: "static" },
    // static -> unsupported is a regression, never an easing
    { id: "stdlib.math.abs", kind: "stdlib", name: "Math.abs", status: "unsupported", code: "SC2020" },
    // same tier, semantic note changed
    { id: "stdlib.date.now", kind: "stdlib", name: "Date.now", status: "static", note: "the live clock, reformed" },
    // unsupported -> dynamic-only eases without becoming usable
    { id: "syntax.namespaces", kind: "syntax", name: "namespaces", status: "dynamic-only", code: "SC1090" },
    // node-builtin.tty removed; one entry added
    { id: "node-builtin.sqlite", kind: "node-builtin", name: "sqlite", status: "static" },
  ]);

  const run = spawnSync(process.execPath, [diffScript, oldManifest, newManifest, "--json"], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  const diff = JSON.parse(run.stdout);

  assert.deepEqual(diff.flippedToStatic.map((e: { id: string }) => e.id), ["diagnostic.sc1070"]);
  assert.equal(diff.flippedToStatic[0].oldStatus, "unsupported");
  assert.equal(diff.flippedToStatic[0].oldCode, "SC1070");
  assert.equal(diff.retirementsDue.length, 1);
  assert.equal(diff.retirementsDue[0].id, "diagnostic.sc1070");
  assert.deepEqual(diff.tierRegressions.map((e: { id: string }) => e.id), ["stdlib.math.abs"]);
  assert.deepEqual(diff.otherTierMoves.map((e: { id: string }) => e.id), ["syntax.namespaces"]);
  assert.deepEqual(diff.added.map((e: { id: string }) => e.id), ["node-builtin.sqlite"]);
  assert.deepEqual(diff.removed.map((e: { id: string }) => e.id), ["node-builtin.tty"]);
  assert.deepEqual(diff.noteChanges.map((e: { id: string }) => e.id), ["stdlib.date.now"]);

  // The human rendering must succeed on the same inputs.
  const human = spawnSync(process.execPath, [diffScript, oldManifest, newManifest], { encoding: "utf8" });
  assert.equal(human.status, 0, human.stderr);
  assert.match(human.stdout, /flipped to static/);
  assert.match(human.stdout, /retirements due/);
});

test("surface_manifest_diff refuses unknown schema versions", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "surface-diff-"));
  const good = writeManifest(dir, "good.json", "0.0.1", []);
  const bad = path.join(dir, "bad.json");
  fs.writeFileSync(bad, JSON.stringify({ schemaVersion: 2, compilerVersion: "9.9.9", entries: [] }));
  const run = spawnSync(process.execPath, [diffScript, good, bad], { encoding: "utf8" });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /schemaVersion 2/);
});

test("identical manifests diff to no differences", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "surface-diff-"));
  const entries = [{ id: "stdlib.math.abs", kind: "stdlib", name: "Math.abs", status: "static" }];
  const a = writeManifest(dir, "a.json", "0.0.1", entries);
  const b = writeManifest(dir, "b.json", "0.0.1", entries);
  const run = spawnSync(process.execPath, [diffScript, a, b], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /no differences\./);
});

test("the committed service-surface reference passes the claim check", () => {
  const run = spawnSync(process.execPath, [genScript, "--check"], { encoding: "utf8" });
  assert.equal(
    run.status,
    0,
    `the gate's surface-claims step would fail:\n${run.stdout}${run.stderr}`,
  );
});
