// The compile-surface tooling, held to its contract: the manifest diff
// categorizes every change class by stable id (flips to static carry
// their cross-layer audit call-outs; regressions never masquerade as
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
const repo = path.resolve(pkg, "..", "..");
const diffScript = path.join(pkg, "scripts", "surface_manifest_diff.mjs");
const genScript = path.join(pkg, "scripts", "gen_service_surface.mjs");
const surfaceReference = path.join(repo, "skill-data", "ts-services", "references", "service-surface.md");
const serviceSkill = path.join(repo, "skill-data", "ts-services", "SKILL.md");

function writeManifest(
  dir: string,
  name: string,
  version: string,
  entries: unknown[],
  coverage: string[] = [],
): string {
  const file = path.join(dir, name);
  fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, compilerVersion: version, coverage, entries }));
  return file;
}

function generatorFixture(entries: unknown[]) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "surface-generator-"));
  const core = path.join(root, "packages", "core");
  const scriptDir = path.join(core, "scripts");
  const manifestDir = path.join(core, "node_modules", "@scriptc", "compiler");
  fs.mkdirSync(scriptDir, { recursive: true });
  fs.mkdirSync(manifestDir, { recursive: true });
  fs.copyFileSync(genScript, path.join(scriptDir, "gen_service_surface.mjs"));
  fs.writeFileSync(path.join(core, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
  fs.writeFileSync(path.join(manifestDir, "surface-manifest.json"), JSON.stringify({
    schemaVersion: 1,
    compilerVersion: "0.0.29",
    coverage: [],
    entries,
  }));
  return {
    root,
    script: path.join(scriptDir, "gen_service_surface.mjs"),
    output: path.join(root, "skill-data", "ts-services", "references", "service-surface.md"),
  };
}

function diffToolFixture(pin: string, manifestVersion: string) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "surface-diff-tool-"));
  const core = path.join(root, "packages", "core");
  const scriptDir = path.join(core, "scripts");
  const manifestDir = path.join(core, "node_modules", "@scriptc", "compiler");
  fs.mkdirSync(scriptDir, { recursive: true });
  fs.mkdirSync(manifestDir, { recursive: true });
  fs.copyFileSync(diffScript, path.join(scriptDir, "surface_manifest_diff.mjs"));
  fs.writeFileSync(path.join(core, "package.json"), JSON.stringify({ dependencies: { scriptc: pin } }));
  fs.writeFileSync(path.join(manifestDir, "surface-manifest.json"), JSON.stringify({
    schemaVersion: 1,
    compilerVersion: manifestVersion,
    coverage: [],
    entries: [],
  }));
  return path.join(scriptDir, "surface_manifest_diff.mjs");
}

test("surface_manifest_diff categorizes every change class by stable id", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "surface-diff-"));
  const oldManifest = writeManifest(dir, "old.json", "0.0.1", [
    { id: "diagnostic.sc1070", kind: "diagnostic-fence", name: "async/await", status: "unsupported", code: "SC1070", note: "sync-only operations" },
    { id: "stdlib.math.abs", kind: "stdlib", name: "Math.abs", status: "static" },
    { id: "stdlib.date.now", kind: "stdlib", name: "Date.now", status: "static", note: "the live clock" },
    { id: "syntax.namespaces", kind: "syntax", name: "namespaces", status: "unsupported", code: "SC1090" },
    { id: "node-builtin.tty", kind: "node-builtin", name: "tty", status: "static" },
  ]);
  const newManifest = writeManifest(dir, "new.json", "0.0.2", [
    // A watched flip whose code, note, and name also change: every applicable
    // category must retain the change instead of the tier move hiding it.
    { id: "diagnostic.sc1070", kind: "diagnostic-fence", name: "async functions", status: "static", note: "native async operations" },
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
  assert.equal(diff.followUpAudits.length, 1);
  assert.equal(diff.followUpAudits[0].id, "diagnostic.sc1070");
  assert.match(diff.followUpAudits[0].audit, /service operations remain synchronous/);
  assert.ok(!("retirementsDue" in diff));
  assert.deepEqual(diff.tierRegressions.map((e: { id: string }) => e.id), ["stdlib.math.abs"]);
  assert.deepEqual(diff.otherTierMoves.map((e: { id: string }) => e.id), ["syntax.namespaces"]);
  assert.deepEqual(diff.added.map((e: { id: string }) => e.id), ["node-builtin.sqlite"]);
  assert.deepEqual(diff.removed.map((e: { id: string }) => e.id), ["node-builtin.tty"]);
  assert.deepEqual(diff.codeChanges.map((e: { id: string }) => e.id), ["diagnostic.sc1070", "stdlib.math.abs"]);
  assert.deepEqual(diff.noteChanges.map((e: { id: string }) => e.id), ["diagnostic.sc1070", "stdlib.date.now"]);
  assert.deepEqual(diff.nameChanges.map((e: { id: string }) => e.id), ["diagnostic.sc1070"]);

  // The human rendering must succeed on the same inputs.
  const human = spawnSync(process.execPath, [diffScript, oldManifest, newManifest], { encoding: "utf8" });
  assert.equal(human.status, 0, human.stderr);
  assert.match(human.stdout, /flipped to static/);
  assert.match(human.stdout, /follow-up audits due/);
  assert.match(human.stdout, /compiler support alone does not retire Native contract\/runtime constraints/);
  assert.match(human.stdout, /service operations remain synchronous/);
  assert.doesNotMatch(human.stdout, /async entry points become possible|delete in the same commit|retirements due/);
  assert.match(human.stdout, /SC1070 -> \(none\)/);
  assert.match(human.stdout, /old: sync-only operations/);
  assert.match(human.stdout, /new: native async operations/);
  assert.match(human.stdout, /"async\/await" -> "async functions"/);
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

test("surface_manifest_diff refuses a stale install for the pinned spec", () => {
  const script = diffToolFixture("0.0.29", "0.0.25");
  const run = spawnSync(process.execPath, [script, "pinned", "pinned"], { encoding: "utf8" });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /installed compiler manifest is 0\.0\.25/);
  assert.match(run.stderr, /package\.json pins scriptc 0\.0\.29/);
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

test("surface_manifest_diff reports coverage-only scope changes", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "surface-diff-"));
  const entries = [{ id: "stdlib.math.abs", kind: "stdlib", name: "Math.abs", status: "static" }];
  const oldManifest = writeManifest(dir, "old.json", "0.0.1", entries, ["timers are not projected"]);
  const newManifest = writeManifest(dir, "new.json", "0.0.2", entries, ["timers are projected"]);

  const jsonRun = spawnSync(process.execPath, [diffScript, oldManifest, newManifest, "--json"], { encoding: "utf8" });
  assert.equal(jsonRun.status, 0, jsonRun.stderr);
  const diff = JSON.parse(jsonRun.stdout);
  assert.deepEqual(diff.coverageChanges, {
    added: ["timers are projected"],
    removed: ["timers are not projected"],
  });

  const human = spawnSync(process.execPath, [diffScript, oldManifest, newManifest], { encoding: "utf8" });
  assert.equal(human.status, 0, human.stderr);
  assert.match(human.stdout, /coverage statements added[\s\S]*\+ timers are projected/);
  assert.match(human.stdout, /coverage statements removed[\s\S]*- timers are not projected/);
  assert.doesNotMatch(human.stdout, /no differences\./);
});

test("the committed service-surface reference passes the claim check", () => {
  const run = spawnSync(process.execPath, [genScript, "--check"], { encoding: "utf8" });
  assert.equal(
    run.status,
    0,
    `the gate's surface-claims step would fail:\n${run.stdout}${run.stderr}`,
  );
});

test("service authoring describes the manifest as a projection, not a complete language census", () => {
  const skill = fs.readFileSync(serviceSkill, "utf8");
  assert.match(skill, /every surface the compiler currently projects/);
  assert.match(skill, /explicit coverage limits/);
  assert.doesNotMatch(skill, /every module, member, and syntax form/);
});

test("the generated reference keeps subpath modules and unknown kinds visible", () => {
  const fixture = generatorFixture([
    { id: "node-builtin.fs", kind: "node-builtin", name: "fs", status: "static", note: "recognized module (bare and node:-prefixed specifiers)" },
    { id: "node-builtin.fs.promises", kind: "node-builtin", name: "fs/promises", status: "static", note: "recognized module (bare and node:-prefixed specifiers)" },
    { id: "node-builtin.fs.promises.readFile", kind: "node-builtin", name: "fs/promises.readFile", status: "static" },
    { id: "node-builtin.sqlite", kind: "node-builtin", name: "node:sqlite", status: "static", note: "recognized module (node:-prefixed specifier only, matching Node)" },
    { id: "host-capability.clipboard", kind: "host-capability", name: "clipboard", status: "unsupported", code: "SC2999" },
  ]);
  const run = spawnSync(process.execPath, [fixture.script], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);

  const rendered = fs.readFileSync(fixture.output, "utf8");
  const moduleEnd = rendered.indexOf("### Module member surface");
  const moduleSection = rendered.slice(rendered.indexOf("## Node built-in modules"), moduleEnd);
  const memberSection = rendered.slice(moduleEnd, rendered.indexOf("## Standard library"));
  assert.ok(moduleSection.includes("`node-builtin.fs.promises`"));
  assert.ok(!moduleSection.includes("`node-builtin.fs.promises.readFile`"));
  assert.ok(moduleSection.includes("`node-builtin.sqlite`"));
  assert.match(moduleSection, /accepted specifier forms[\s\S]*node:-prefixed specifier only/);
  assert.doesNotMatch(moduleSection, /except\s+`node:test`/);
  assert.ok(memberSection.includes("`node-builtin.fs.promises.readFile`"));
  assert.match(rendered, /### `host-capability`[\s\S]*`host-capability\.clipboard`/);
});

test("the generated reference escapes manifest text for Markdown tables", () => {
  const fixture = generatorFixture([
    {
      id: "syntax.generic-value",
      kind: "syntax",
      name: "generic <T> & value",
      status: "static",
      note: "Use ReadableStream<Uint8Array> & bytes",
    },
  ]);
  const run = spawnSync(process.execPath, [fixture.script], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);

  const rendered = fs.readFileSync(fixture.output, "utf8");
  assert.match(rendered, /generic &lt;T&gt; &amp; value/);
  assert.match(rendered, /ReadableStream&lt;Uint8Array&gt; &amp; bytes/);
  assert.doesNotMatch(rendered, /generic <T>|ReadableStream<Uint8Array>/);
});

test("the generated reference derives the missing-lowering refusal code from the manifest", () => {
  const fixture = generatorFixture([
    {
      id: "diagnostic.custom-lowering-fence",
      kind: "diagnostic-fence",
      name: "standard-library or @types/node surface with no lowering",
      status: "unsupported",
      code: "SC2998",
    },
  ]);
  const run = spawnSync(process.execPath, [fixture.script], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);

  const rendered = fs.readFileSync(fixture.output, "utf8");
  assert.match(rendered, /outside the lowered set are refused per site with `SC2998`/);
  assert.doesNotMatch(rendered, /SC2020/);
});

test("the claim scan covers Markdown formatting and docs while ignoring unrelated compiler versions", () => {
  const fixture = generatorFixture([]);
  const write = spawnSync(process.execPath, [fixture.script], { encoding: "utf8" });
  assert.equal(write.status, 0, write.stderr);

  const skillDir = path.join(fixture.root, "skills", "example");
  fs.mkdirSync(skillDir, { recursive: true });
  const skill = path.join(skillDir, "SKILL.md");
  fs.writeFileSync(skill, "Install `some-package@0.0.1` for this example.\n");
  const unrelated = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(unrelated.status, 0, unrelated.stderr);

  fs.writeFileSync(skill, "The pinned scriptc compiler\nversion `0.0.29` was used for this calibration.\n");
  const current = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(current.status, 0, current.stderr);

  fs.writeFileSync(skill, "The pinned scriptc compiler\nversion `0.0.25` was used for this calibration.\n");
  const stale = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(stale.status, 1);
  assert.match(stale.stderr, /skills\/example\/SKILL\.md:2:/);
  assert.match(stale.stderr, /compiler version 0\.0\.25 but the pin is 0\.0\.29/);

  fs.writeFileSync(skill, "Compiler support was measured with scriptc version: `0.0.24`.\n");
  const punctuated = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(punctuated.status, 1);
  assert.match(punctuated.stderr, /skills\/example\/SKILL\.md:1:/);
  assert.match(punctuated.stderr, /compiler version 0\.0\.24 but the pin is 0\.0\.29/);

  fs.writeFileSync(skill, "The scriptc compiler pin is 0.0.23.\n");
  const pinClaim = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(pinClaim.status, 1);
  assert.match(pinClaim.stderr, /skills\/example\/SKILL\.md:1:/);
  assert.match(pinClaim.stderr, /compiler version 0\.0\.23 but the pin is 0\.0\.29/);

  fs.writeFileSync(skill, "The Zig compiler version is 0.16.0.\n");
  const otherCompiler = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(otherCompiler.status, 0, otherCompiler.stderr);

  fs.writeFileSync(skill, "The Zig 0.16.0 calibration established these timings.\nThe Node 24.15.0 spike covers fetch.\n");
  const unrelatedCalibration = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(unrelatedCalibration.status, 0, unrelatedCalibration.stderr);

  fs.writeFileSync(skill, "The scriptc 0.0.22 calibration established this service surface.\n");
  const scriptcCalibration = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(scriptcCalibration.status, 1);
  assert.match(scriptcCalibration.stderr, /compiler version 0\.0\.22 but the pin is 0\.0\.29/);

  for (const formattedVersion of ["**0.0.22**", "_0.0.21_", "```0.0.20```"]) {
    fs.writeFileSync(skill, `The scriptc version is ${formattedVersion}.\n`);
    const formatted = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
    assert.equal(formatted.status, 1, `${formattedVersion} was not caught: ${formatted.stderr}`);
    assert.match(formatted.stderr, /skills\/example\/SKILL\.md:1:/);
  }

  fs.writeFileSync(skill, "The Zig compiler version is 0.16.0.\n");
  const docsDir = path.join(fixture.root, "docs");
  fs.mkdirSync(docsDir, { recursive: true });
  fs.writeFileSync(path.join(docsDir, "README.md"), "The scriptc version is **0.0.19**.\n");
  const topLevelDocs = spawnSync(process.execPath, [fixture.script, "--check"], { encoding: "utf8" });
  assert.equal(topLevelDocs.status, 1);
  assert.match(topLevelDocs.stderr, /docs\/README\.md:1:/);
});

test("every recognized built-in module is in the committed module table", () => {
  const manifest = JSON.parse(fs.readFileSync(
    path.join(pkg, "node_modules", "@scriptc", "compiler", "surface-manifest.json"),
    "utf8",
  ));
  const rendered = fs.readFileSync(surfaceReference, "utf8");
  const moduleSection = rendered.slice(
    rendered.indexOf("## Node built-in modules"),
    rendered.indexOf("### Module member surface"),
  );
  for (const entry of manifest.entries.filter((candidate: { kind: string; note?: string }) =>
    candidate.kind === "node-builtin" && candidate.note?.startsWith("recognized module"))) {
    assert.ok(moduleSection.includes(`| \`${entry.id}\` |`), `${entry.id} is missing from the recognized-module table`);
  }
});
