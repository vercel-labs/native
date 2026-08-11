#!/usr/bin/env node
// Empirical service-package probe for the compiler pin carried by this SDK.
// These are deliberately small, common data/text utilities already locked in
// the docs workspace, so the spike needs no network and judges exact bytes.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const coreRoot = path.resolve(here, "..");
const repoRoot = path.resolve(coreRoot, "..", "..");
const compilerJs = createRequire(path.join(coreRoot, "package.json")).resolve("scriptc/dist/main.js");
const compilerVersion = JSON.parse(fs.readFileSync(path.join(coreRoot, "package.json"), "utf8")).dependencies.scriptc;

const candidates = [
  { name: "escape-string-regexp", version: "5.0.0", source: 'import escape from "escape-string-regexp";\nconsole.log(escape("a.b"));\n' },
  { name: "comma-separated-tokens", version: "2.0.3", source: 'import { parse } from "comma-separated-tokens";\nconsole.log(parse("a,b").length);\n' },
  { name: "space-separated-tokens", version: "2.0.2", source: 'import { parse } from "space-separated-tokens";\nconsole.log(parse("a b").length);\n' },
  { name: "nanoid", version: "3.3.15", source: 'import { nanoid } from "nanoid";\nconsole.log(nanoid(4));\n' },
  { name: "micromark", version: "4.0.2", source: 'import { micromark } from "micromark";\nconsole.log(micromark("# hi"));\n' },
];

function pnpmNodeModules(candidate) {
  const spelling = `${candidate.name.replaceAll("/", "+")}@${candidate.version}`;
  const exact = path.join(repoRoot, "docs", "node_modules", ".pnpm", spelling, "node_modules");
  if (fs.statSync(exact, { throwIfNoEntry: false })?.isDirectory()) return exact;
  throw new Error(`locked spike source is missing: ${exact}; run pnpm --dir docs install`);
}

const results = [];
for (const candidate of candidates) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "native-npm-static-spike-"));
  try {
    fs.symlinkSync(pnpmNodeModules(candidate), path.join(scratch, "node_modules"), "dir");
    const entry = path.join(scratch, "probe.ts");
    fs.writeFileSync(entry, candidate.source);
    const probe = spawnSync(process.execPath, [compilerJs, "coverage", entry, "--npm-static", candidate.name], { encoding: "utf8" });
    const output = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
    if (process.env.NATIVE_NPM_STATIC_SPIKE_VERBOSE === "1") {
      process.stderr.write(`\n===== ${candidate.name}@${candidate.version} =====\n${output}\n`);
    }
    const fallback = /island fallback/i.test(output);
    const staticPercent = Number(output.match(/compile statically\s+\d+\s+\((\d+)%\)/i)?.[1] ?? "-1");
    const reason = output.match(/island fallback\s*\(([^\n)]+(?:\)[^\n)]*)?)/i)?.[1]
      ?? output.match(/error\s+(SC\d+)[^\n]*/i)?.[0]
      ?? (staticPercent >= 0 && staticPercent < 100 ? `only ${staticPercent}% of analyzed statements compile statically` : null)
      ?? (probe.status === 0 ? "static coverage accepted" : "coverage command failed without a diagnostic");
    results.push({
      package: candidate.name,
      version: candidate.version,
      verdict: probe.status === 0 && !fallback && staticPercent === 100 ? "static" : "refused",
      static_percent: staticPercent,
      reason: reason.trim(),
    });
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

process.stdout.write(JSON.stringify({ compiler: `scriptc ${compilerVersion}`, policy: "explicit --npm-static; no auto or dynamic fallback", candidates: results }, null, 2) + "\n");
