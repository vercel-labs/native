#!/usr/bin/env node
// Generate the author-facing service compile-surface reference from the
// PINNED compiler's own surface manifest, and gate hand-written
// capability claims against it. Compiler capability facts (what
// services can use, which SC code refuses what) drift into folklore
// when they are hand-maintained prose; here they are byte-derived from
// packages/core/node_modules/@scriptc/compiler/surface-manifest.json,
// so a pin move regenerates them and a stale claim fails a check
// instead of surviving on memory.
//
//   node gen_service_surface.mjs           # (re)write the reference
//   node gen_service_surface.mjs --check   # verify, changing nothing
//
// Output: skill-data/ts-services/references/service-surface.md
//
// --check fails (exit 1) when:
//   - the checked-in reference is missing or not byte-identical to a
//     regeneration from the installed manifest (pin moved without
//     regenerating, or the file was hand-edited);
//   - the manifest's compilerVersion disagrees with the scriptc pin in
//     packages/core/package.json (stale install — run
//     `npm ci --include=dev` in packages/core);
//   - an SC diagnostic code (SC0000..SC9999) appears in docs/, skills/,
//     or skill-data/ outside the generated reference — compiler
//     capability claims live in the generated table, never in prose;
//   - a scriptc version literal (0.0.N) in those same trees names a
//     version other than the pin — the calibration/spike sentences the
//     docs carry must move with the pin.
//
// Exit 2: the compiler manifest is not installed or unreadable.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const KNOWN_SCHEMA_VERSION = 1;
const coreRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(coreRoot, "..", "..");
const manifestPath = path.join(coreRoot, "node_modules", "@scriptc", "compiler", "surface-manifest.json");
const outputRel = "skill-data/ts-services/references/service-surface.md";
const outputPath = path.join(repoRoot, outputRel);

const check = process.argv.includes("--check");

if (!fs.existsSync(manifestPath)) {
  console.error("gen_service_surface: the pinned compiler is not installed — run `npm ci --include=dev` in the SDK's packages/core");
  process.exit(2);
}
let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
} catch (error) {
  console.error(`gen_service_surface: cannot read ${manifestPath}: ${error.message}`);
  process.exit(2);
}
if (manifest.schemaVersion !== KNOWN_SCHEMA_VERSION) {
  console.error(`gen_service_surface: manifest schemaVersion ${manifest.schemaVersion} is unknown (this tool knows ${KNOWN_SCHEMA_VERSION}) — update the tool before regenerating`);
  process.exit(2);
}

// ---- render ---------------------------------------------------------------

const cell = (text) =>
  text === undefined ? "" : String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("|", "\\|")
    .replaceAll(/\r?\n/g, " ");
const byId = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

function table(entries, { withCode = true } = {}) {
  const lines = [];
  lines.push(withCode ? "| Entry id | Surface | Status | Refusal code | Notes |" : "| Entry id | Surface | Status | Notes |");
  lines.push(withCode ? "|---|---|---|---|---|" : "|---|---|---|---|");
  for (const e of [...entries].sort(byId)) {
    const cols = [`\`${e.id}\``, cell(e.name), e.status];
    if (withCode) cols.push(e.code ? `\`${e.code}\`` : "");
    cols.push(cell(e.note));
    lines.push(`| ${cols.join(" | ")} |`);
  }
  return lines.join("\n");
}

const kinds = { syntax: [], "diagnostic-fence": [], "node-builtin": [], stdlib: [] };
const unknownKinds = new Set();
for (const e of manifest.entries) {
  (kinds[e.kind] ?? (unknownKinds.add(e.kind), (kinds[e.kind] = []))).push(e);
}
const counts = { static: 0, "dynamic-only": 0, unsupported: 0 };
for (const e of manifest.entries) counts[e.status] = (counts[e.status] ?? 0) + 1;

const isBuiltinModule = (entry) => !entry.name.includes(".");
const builtinModules = kinds["node-builtin"].filter(isBuiltinModule);
const builtinMembers = kinds["node-builtin"].filter((entry) => !isBuiltinModule(entry));
const missingLoweringFence = kinds["diagnostic-fence"].find((entry) =>
  entry.name === "standard-library or @types/node surface with no lowering");
const constrainedCallRefusal = missingLoweringFence?.code
  ? `outside the lowered set are refused per site with \`${missingLoweringFence.code}\`.`
  : "outside the lowered set are refused with the applicable diagnostic fence listed below.";

const sections = [];
sections.push(`<!-- GENERATED FILE — do not edit by hand.
     Derived byte-for-byte from the pinned compiler's surface manifest:
       packages/core/node_modules/@scriptc/compiler/surface-manifest.json
     Regenerate after any compiler pin move:
       node packages/core/scripts/gen_service_surface.mjs
     Verify without writing:
       node packages/core/scripts/gen_service_surface.mjs --check -->

# Service compile surface — scriptc ${manifest.compilerVersion}

What TypeScript under \`src/services/\` can use, as stated by the pinned
compiler itself (surface manifest schema ${manifest.schemaVersion}, ${manifest.entries.length} entries:
${counts.static} static, ${counts["dynamic-only"]} dynamic-only, ${counts.unsupported} unsupported).

How to read the tables:

- **static** — compiles in the engine-free static tier services use.
- **dynamic-only** — needs the embedded dynamic engine (\`--dynamic\`),
  which Native SDK builds never pass, so for services this means
  **unavailable** until the entry goes static.
- **unsupported** — refused with the listed SC code. A status describes
  where the named code is *raised*: forms outside the supported subset
  refuse with that code, while supported forms appear as their own
  static entries.
- Absence from the manifest means "not projected by the compiler's
  decision tables yet", never "unsupported".
- Standard-library and node-builtin rows name surface whose lowered
  call forms are constrained (arity, argument shapes); call forms
  ${constrainedCallRefusal}`);

sections.push(`## Syntax

${table(kinds.syntax)}`);

sections.push(`## Diagnostic fences

The SC codes an author can hit at the module/program level, and what
each one refuses.

${table(kinds["diagnostic-fence"])}`);

sections.push(`## Node built-in modules

Recognized modules and their accepted specifier forms, as stated by each
manifest row in the Notes column:

${table(builtinModules, { withCode: false })}

### Module member surface

${table(builtinMembers)}`);

sections.push(`## Standard library

${table(kinds.stdlib)}`);

if (unknownKinds.size > 0) {
  const otherTables = [...unknownKinds].sort().map((kind) => `### \`${kind}\`

${table(kinds[kind])}`).join("\n\n");
  sections.push(`## Other entries

Entry kinds this generator does not know yet. Their manifest rows are
preserved here; update the generator when a dedicated section would make
the reference clearer.

${otherTables}`);
}

sections.push(`## Compiler coverage statement

The manifest's own description of how it is projected and what its
statuses promise, verbatim:

${(manifest.coverage ?? []).map((c) => `- ${c}`).join("\n")}`);

const rendered = sections.join("\n\n") + "\n";

// ---- write mode -----------------------------------------------------------

if (!check) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, rendered);
  console.log(`wrote ${outputRel} (compiler ${manifest.compilerVersion}, ${manifest.entries.length} entries)`);
  process.exit(0);
}

// ---- check mode -----------------------------------------------------------

const problems = [];

// 1. Reference file freshness: byte-identical to regeneration.
const existing = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, "utf8") : null;
if (existing === null) {
  problems.push(`${outputRel} is missing — generate it: node packages/core/scripts/gen_service_surface.mjs`);
} else if (existing !== rendered) {
  problems.push(`${outputRel} does not match the installed compiler manifest (pin moved without regenerating, or the file was hand-edited) — regenerate: node packages/core/scripts/gen_service_surface.mjs`);
}

// 2. Pin sanity: the installed manifest is the pinned compiler's.
const pkg = JSON.parse(fs.readFileSync(path.join(coreRoot, "package.json"), "utf8"));
const pin = pkg.dependencies?.scriptc;
if (manifest.compilerVersion !== pin) {
  problems.push(`installed compiler manifest is ${manifest.compilerVersion} but packages/core/package.json pins scriptc ${pin} — run \`npm ci --include=dev\` in packages/core`);
}

// 3+4. Claim scan: SC codes and scriptc version literals in prose.
function proseFiles() {
  const roots = ["docs", "skills", "skill-data"];
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name.startsWith(".next")) continue;
        walk(full);
      } else if (/\.(md|mdx)$/.test(entry.name)) {
        files.push(full);
      }
    }
  };
  for (const root of roots) {
    const full = path.join(repoRoot, root);
    if (fs.existsSync(full)) walk(full);
  }
  return files.filter((f) => path.resolve(f) !== outputPath);
}

// Only semver literals in explicit compiler context are scriptc claims.
// Package examples such as `some-package@0.0.1` are unrelated and must
// remain legal in authoring docs.
const semver = String.raw`\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?`;
const markdownWrapper = "(?:`{1,3}|\\*{1,3}|_{1,3})?";
const scriptcContext = String.raw`scriptc(?:\s+compiler)?(?:'s)?(?:\s+(?:version|pin))?`;
const versionJoin = String.raw`(?:\s+(?:(?:is|at)\s*)?[:=]?\s*|[:=]\s*)`;
const versionClaim = new RegExp(
  String.raw`\b${scriptcContext}${versionJoin}${markdownWrapper}(?<![\d.])(?<version>${semver})(?!\d|\.\d)${markdownWrapper}`,
  "gi",
);
const scClaim = /\bSC\d{4}\b/g;
const lineNumberAt = (text, offset) =>
  1 + (text.slice(0, offset).match(/\n/g)?.length ?? 0);

for (const file of proseFiles()) {
  const rel = path.relative(repoRoot, file);
  const text = fs.readFileSync(file, "utf8");
  for (const match of text.matchAll(scClaim)) {
    const line = lineNumberAt(text, match.index);
    problems.push(`${rel}:${line}: hand-written compiler capability claim \`${match[0]}\` — SC codes live only in the generated ${outputRel}; state the fact there (regenerate) and link or describe it here without the code`);
  }
  for (const match of text.matchAll(versionClaim)) {
    const claimedVersion = match.groups.version;
    if (claimedVersion !== pin) {
      const versionOffset = match.index + match[0].indexOf(claimedVersion);
      const line = lineNumberAt(text, versionOffset);
      problems.push(`${rel}:${line}: names compiler version ${claimedVersion} but the pin is ${pin} — refresh the sentence (calibration/spike claims move with the pin)`);
    }
  }
}

if (problems.length > 0) {
  console.error(`service surface check: ${problems.length} problem(s)\n`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log(`service surface check: ${outputRel} matches compiler ${manifest.compilerVersion}; no hand-written SC-code or stale version claims in docs/, skills/, skill-data/`);
