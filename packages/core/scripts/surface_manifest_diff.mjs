#!/usr/bin/env node
// Mechanical diff of two scriptc surface manifests, keyed by their
// stable entry ids — the pre-flight for every compiler pin move. The
// manifest (schemaVersion 1) is the compiler's own machine-readable
// statement of what compiles (`static`), what needs the dynamic engine
// this SDK never enables (`dynamic-only`), and what refuses with which
// SC code (`unsupported`); diffing old pin against candidate turns
// "what changed upstream?" into a checklist instead of folklore:
//
//   - entries flipped to static      -> compile fixtures to add BEFORE
//                                       the pin moves (supported must
//                                       compile; each flip may also
//                                       retire a staging transform or a
//                                       docs/skill caveat — flagged
//                                       below when the id is watched)
//   - tier regressions               -> surface the candidate REMOVED;
//                                       audit before moving anything
//   - new / removed entries          -> projection growth or upstream
//                                       renames (a rename shows as
//                                       remove+add; ids are stable, so
//                                       treat removals as suspect)
//   - semantic note / SC-code moves  -> teaching text and fence codes
//                                       that docs or checks may echo
//
//   node surface_manifest_diff.mjs <old> <new> [--json]
//
// <old>/<new> each resolve, in order: a surface-manifest.json path; a
// directory containing one (directly, or under its
// node_modules/@scriptc/compiler/); the word "pinned" (this package's
// installed compiler); or a version X.Y.Z, accepted only if it matches
// the installed compiler — other versions must be fetched by hand
// (`npm pack @scriptc/compiler@X.Y.Z`, extract package/surface-manifest.json)
// so this tool stays offline like the builds it serves.
//
// Exit 0: diff printed (including "no differences"). Exit 2: unusable
// input (unresolvable spec, unknown schema version).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const KNOWN_SCHEMA_VERSION = 1;
const coreRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pinnedManifestPath = path.join(
  coreRoot, "node_modules", "@scriptc", "compiler", "surface-manifest.json");

// Entries whose flip to `static` retires concrete machinery or teaching
// in this repository, so the diff can say "this flip has a chore
// attached" instead of relying on memory. Staging transforms with no
// projected manifest entry yet (readonly-array erasure, alias folding/
// dedupe, record storage in stage_external_core.mjs) are not listed —
// absence from the manifest means "not projected", and their eventual
// entries will surface in the added-entries section first.
const RETIREMENT_WATCH = {
  "diagnostic.sc1012": "default-export caveat in service authoring docs/skills",
  "diagnostic.sc1013": "namespace-import caveat in service authoring docs/skills",
  "diagnostic.sc1014": "re-export/export-list caveat in service authoring docs/skills",
  "diagnostic.sc1031": "destructuring caveat in service authoring docs/skills",
  "diagnostic.sc1070": "sync-only service operations (async entry points become possible)",
  "diagnostic.sc1071": "generator caveat in service authoring docs/skills",
  "syntax.typeof-expressions": "typeof caveat in service authoring docs/skills",
  "syntax.spread-arguments": "spread-argument caveat in service authoring docs/skills",
};

function fail(message) {
  console.error(`surface_manifest_diff: ${message}`);
  process.exit(2);
}

function loadManifest(file, spec) {
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`cannot read manifest for '${spec}' at ${file}: ${error.message}`);
  }
  if (manifest.schemaVersion !== KNOWN_SCHEMA_VERSION) {
    fail(`'${spec}' has manifest schemaVersion ${manifest.schemaVersion}; this tool knows version ${KNOWN_SCHEMA_VERSION} — update the tool before trusting the diff`);
  }
  if (!Array.isArray(manifest.entries)) fail(`'${spec}' has no entries array`);
  return { file, manifest };
}

function resolveSpec(spec) {
  if (spec === "pinned") {
    if (!fs.existsSync(pinnedManifestPath)) {
      fail("the pinned compiler is not installed — run `npm ci --include=dev` in the SDK's packages/core");
    }
    return loadManifest(pinnedManifestPath, spec);
  }
  if (fs.existsSync(spec)) {
    const stat = fs.statSync(spec);
    if (stat.isFile()) return loadManifest(spec, spec);
    for (const candidate of [
      path.join(spec, "surface-manifest.json"),
      path.join(spec, "node_modules", "@scriptc", "compiler", "surface-manifest.json"),
    ]) {
      if (fs.existsSync(candidate)) return loadManifest(candidate, spec);
    }
    fail(`directory '${spec}' contains no surface-manifest.json (looked directly and under node_modules/@scriptc/compiler/)`);
  }
  if (/^\d+\.\d+\.\d+$/.test(spec)) {
    if (fs.existsSync(pinnedManifestPath)) {
      const pinned = loadManifest(pinnedManifestPath, spec);
      if (pinned.manifest.compilerVersion === spec) return pinned;
      fail(`version ${spec} is not the installed compiler (${pinned.manifest.compilerVersion}) — fetch its manifest by hand (npm pack @scriptc/compiler@${spec}, extract package/surface-manifest.json) and pass the path`);
    }
    fail(`version ${spec} cannot be resolved: the pinned compiler is not installed — run \`npm ci --include=dev\` in the SDK's packages/core`);
  }
  fail(`cannot resolve '${spec}': not a file, not a directory, not "pinned", not an installed version`);
}

const args = process.argv.slice(2);
const json = args.includes("--json");
const specs = args.filter((a) => a !== "--json");
if (specs.length !== 2) {
  console.error("usage: surface_manifest_diff.mjs <old> <new> [--json]");
  console.error('  <old>/<new>: manifest path | directory | "pinned" | installed version X.Y.Z');
  process.exit(2);
}

const oldSide = resolveSpec(specs[0]);
const newSide = resolveSpec(specs[1]);

const byId = (m) => new Map(m.entries.map((e) => [e.id, e]));
const oldById = byId(oldSide.manifest);
const newById = byId(newSide.manifest);

// Tier order for regression detection: losing ground means moving DOWN.
const TIER_RANK = { static: 2, "dynamic-only": 1, unsupported: 0 };
const rank = (status) => TIER_RANK[status] ?? -1;

const summarize = (e) => ({
  id: e.id, kind: e.kind, name: e.name, status: e.status,
  ...(e.code !== undefined && { code: e.code }),
  ...(e.note !== undefined && { note: e.note }),
});

const diff = {
  old: { version: oldSide.manifest.compilerVersion, entries: oldSide.manifest.entries.length, file: oldSide.file },
  new: { version: newSide.manifest.compilerVersion, entries: newSide.manifest.entries.length, file: newSide.file },
  flippedToStatic: [],   // any status -> static
  tierRegressions: [],   // static -> dynamic-only/unsupported, dynamic-only -> unsupported
  otherTierMoves: [],    // unsupported -> dynamic-only (eased, but still unusable without --dynamic)
  added: [],
  removed: [],
  codeChanges: [],       // SC code moved, including alongside a tier move
  noteChanges: [],       // semantic note changed, including alongside a tier move
  nameChanges: [],       // same id, display name changed
  retirementsDue: [],    // watched entries among flippedToStatic
};

for (const [id, oldEntry] of oldById) {
  const newEntry = newById.get(id);
  if (!newEntry) { diff.removed.push(summarize(oldEntry)); continue; }
  if (oldEntry.status !== newEntry.status) {
    const move = { ...summarize(newEntry), oldStatus: oldEntry.status, ...(oldEntry.code !== undefined && { oldCode: oldEntry.code }) };
    if (newEntry.status === "static") {
      diff.flippedToStatic.push(move);
      if (RETIREMENT_WATCH[id]) diff.retirementsDue.push({ id, retires: RETIREMENT_WATCH[id] });
    } else if (rank(newEntry.status) < rank(oldEntry.status)) {
      diff.tierRegressions.push(move);
    } else {
      diff.otherTierMoves.push(move);
    }
  }
  if (oldEntry.code !== newEntry.code) {
    diff.codeChanges.push({ id, kind: newEntry.kind, name: newEntry.name, status: newEntry.status, oldCode: oldEntry.code, newCode: newEntry.code });
  }
  if (oldEntry.note !== newEntry.note) {
    diff.noteChanges.push({ id, kind: newEntry.kind, name: newEntry.name, status: newEntry.status, oldNote: oldEntry.note, newNote: newEntry.note });
  }
  if (oldEntry.name !== newEntry.name) {
    diff.nameChanges.push({ id, kind: newEntry.kind, oldName: oldEntry.name, newName: newEntry.name });
  }
}
for (const [id, newEntry] of newById) {
  if (!oldById.has(id)) diff.added.push(summarize(newEntry));
}

if (json) {
  console.log(JSON.stringify(diff, null, 2));
  process.exit(0);
}

const line = (e) => {
  const code = e.code ? ` ${e.code}` : "";
  const from = e.oldStatus ? `${e.oldStatus} -> ` : "";
  return `  ${e.id}  [${from}${e.status}]${code}  ${e.name}`;
};
const clip = (text, max = 110) =>
  text === undefined ? "(none)" : text.length <= max ? text : `${text.slice(0, max - 1)}…`;

console.log(`surface manifest diff: ${diff.old.version} (${diff.old.entries} entries) -> ${diff.new.version} (${diff.new.entries} entries)`);

const section = (title, items, render) => {
  console.log(`\n${title}: ${items.length}`);
  for (const item of items) console.log(render(item));
};

section("flipped to static (add compile fixtures before any pin move)", diff.flippedToStatic, line);
if (diff.retirementsDue.length > 0) {
  console.log("\n  retirements due with these flips (delete in the same commit as the pin move, with the proving fixture):");
  for (const r of diff.retirementsDue) console.log(`    ${r.id}  retires: ${r.retires}`);
}
section("tier regressions (the candidate REMOVED surface — audit before moving)", diff.tierRegressions, line);
section("eased to dynamic-only (still unusable: this SDK never passes --dynamic)", diff.otherTierMoves, line);
section("new entries", diff.added, line);
section("removed entries (stable ids should not vanish — suspect a rename or projection change)", diff.removed, line);
section("SC-code changes", diff.codeChanges,
  (c) => `  ${c.id}  ${c.oldCode ?? "(none)"} -> ${c.newCode ?? "(none)"}  ${c.name}`);
section("semantic note changes", diff.noteChanges, (c) =>
  `  ${c.id}  ${c.name}\n    old: ${clip(c.oldNote)}\n    new: ${clip(c.newNote)}`);
section("name changes", diff.nameChanges, (c) => `  ${c.id}  "${c.oldName}" -> "${c.newName}"`);

const total = diff.flippedToStatic.length + diff.tierRegressions.length + diff.otherTierMoves.length
  + diff.added.length + diff.removed.length + diff.codeChanges.length + diff.noteChanges.length
  + diff.nameChanges.length;
if (total === 0) console.log("\nno differences.");
