#!/usr/bin/env node
// Stage a ts-core app for an external core compile: one scratch tree
// carrying the AUTHOR'S sources verbatim except for mechanical,
// behavior-preserving transforms, the SDK modules they import, the
// static @native-sdk/core restatement, and the generated compile entry
// + profile beside them. The product-lane twin of the fixture driver's
// staging (tests/compiled-core/build_core.sh) — the transforms are the
// same five, ported spelling for spelling, and the paired compiled-core
// batteries hold their output byte-identical to the transpiler lane:
//
//   1. bare-specifier resolution — "@native-sdk/core*" rewrites to the
//      staged ./sdk/ copies (the toolchain compiles from files, not
//      package resolution), relative to each staged file's own depth;
//   2. readonly-array erasure — `readonly T[]` sits outside the
//      toolchain's sidecar type vocabulary today (type-level only);
//   3. Bytes-alias folding — a tabled scalar alias refuses, so staged
//      copies spell Uint8Array directly and drop the alias;
//   4. duplicate-alias dedupe — the static SDK surface drops any alias
//      another staged file declares, so one declaration site survives;
//   5. event-record storage — the staged SDK text/events modules spell
//      their records as object-literal aliases (value storage), the
//      form the host-constructed channel arms need.
//
//   node stage_external_core.mjs --src <app src dir> --sdk <sdk dir>
//     --static <compile-surface core.ts> --facade <core_facade.ts>
//     --profile <core_profile.json> --out <stage dir>

import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--") || value === undefined) {
      console.error("usage: stage_external_core.mjs --src <dir> --sdk <dir> --static <file> --facade <file> --profile <file> --out <dir>");
      process.exit(2);
    }
    args[key.slice(2)] = value;
  }
  for (const required of ["src", "sdk", "static", "facade", "profile", "out"]) {
    if (!(required in args)) {
      console.error(`stage_external_core.mjs: missing --${required}`);
      process.exit(2);
    }
  }
  return args;
}

/// Every .ts file under `dir`, as POSIX-relative paths.
function tsFilesUnder(dir) {
  const out = [];
  const walk = (sub) => {
    for (const entry of fs.readdirSync(path.join(dir, sub), { withFileTypes: true })) {
      const rel = sub === "" ? entry.name : `${sub}/${entry.name}`;
      // The service class has its own compile lane. Keeping it out of the
      // core scratch tree also prevents vendored package declarations from
      // participating in the core surface's mechanical alias dedupe.
      if (entry.isDirectory() && rel !== "services") walk(rel);
      else if (entry.isFile() && rel.endsWith(".ts") && !rel.endsWith(".d.ts")) out.push(rel);
    }
  };
  walk("");
  return out.sort();
}

/// Transform 1-3 on one author source, `rel` staged-relative (the SDK
/// specifiers resolve relative to the file's own directory).
function resolveSpecifiers(text, rel) {
  const toSdk = (name) => {
    const spelled = path.posix.relative(path.posix.dirname(rel), `sdk/${name}`);
    return spelled.startsWith(".") ? spelled : `./${spelled}`;
  };
  return text
    .replaceAll('"@native-sdk/core/text"', `"${toSdk("text.ts")}"`)
    .replaceAll('"@native-sdk/core/events"', `"${toSdk("events.ts")}"`)
    .replaceAll('"@native-sdk/core"', `"${toSdk("core.ts")}"`)
    .replaceAll('"@native-sdk/services"', `"${path.posix.relative(path.posix.dirname(rel), "services.gen.ts").startsWith(".") ? path.posix.relative(path.posix.dirname(rel), "services.gen.ts") : `./${path.posix.relative(path.posix.dirname(rel), "services.gen.ts")}`}"`)
    .replace(/readonly ([A-Za-z_][A-Za-z0-9_]*(?:<[A-Za-z_, ]*>)?)\[\]/g, "$1[]")
    .replace(/(?<![A-Za-z0-9_])Bytes(?![A-Za-z0-9_])/g, "Uint8Array")
    .split("\n")
    .filter((line) => line !== "export type Uint8Array = Uint8Array;" && !/^ *type Uint8Array,$/.test(line))
    .map((line) => line.replaceAll("type Uint8Array, ", "").replace(/, type Uint8Array([,}])/g, "$1"))
    .join("\n");
}

/// The names of `export type X = ...` declarations in a staged file
/// (the dedupe set for the static SDK surface).
function exportedAliasNames(text) {
  const names = [];
  for (const line of text.split("\n")) {
    const match = /^export type ([A-Za-z0-9_]+) =/.exec(line);
    if (match) names.push(match[1]);
  }
  return names;
}

/// Transform 4: drop the static surface's copy of any alias another
/// staged file declares (single-line aliases and multi-line ones,
/// through the terminating `;`).
function dedupeAliases(text, dropNames) {
  const drop = new Set(dropNames);
  const out = [];
  let skipping = false;
  for (const line of text.split("\n")) {
    if (skipping) {
      if (/;[ \t]*$/.test(line)) skipping = false;
      continue;
    }
    const match = /^export type ([A-Za-z0-9_]+) =/.exec(line);
    if (match && drop.has(match[1])) {
      if (!/;[ \t]*$/.test(line)) skipping = true;
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

const args = parseArgs(process.argv);
fs.rmSync(args.out, { recursive: true, force: true });
fs.mkdirSync(path.join(args.out, "sdk"), { recursive: true });

// Author sources, at their entry-relative (src-relative) paths.
const authorFiles = tsFilesUnder(args.src);
const aliasNames = [];
for (const rel of authorFiles) {
  const staged = resolveSpecifiers(fs.readFileSync(path.join(args.src, rel), "utf8"), rel);
  fs.mkdirSync(path.dirname(path.join(args.out, rel)), { recursive: true });
  fs.writeFileSync(path.join(args.out, rel), staged);
  aliasNames.push(...exportedAliasNames(staged));
}

// Transform 5: the staged SDK library modules spell their exported
// records as object-literal aliases (value storage).
for (const sdkFile of ["text.ts", "events.ts"]) {
  const staged = fs
    .readFileSync(path.join(args.sdk, sdkFile), "utf8")
    .replace(/^export interface ([A-Za-z0-9_]+) \{/gm, "export type $1 = {");
  fs.writeFileSync(path.join(args.out, "sdk", sdkFile), staged);
  aliasNames.push(...exportedAliasNames(staged));
}

// The static @native-sdk/core restatement, deduped against every alias
// another staged file declares.
fs.writeFileSync(path.join(args.out, "sdk", "core.ts"), dedupeAliases(fs.readFileSync(args.static, "utf8"), aliasNames));

// The generated compile entry and its profile, staged under the names
// the profile's entry spelling expects.
fs.copyFileSync(args.facade, path.join(args.out, "core_facade.ts"));
fs.copyFileSync(args.profile, path.join(args.out, "profile.json"));
if (args["services-client"]) {
  const client = resolveSpecifiers(fs.readFileSync(args["services-client"], "utf8"), "services.gen.ts");
  fs.writeFileSync(path.join(args.out, "services.gen.ts"), client);
}
