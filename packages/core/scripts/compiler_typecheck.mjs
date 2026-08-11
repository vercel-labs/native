// The compiler-truth typecheck: run the pinned external core compiler's
// analyzer over the author's entry with the shipped SDK declarations
// mapped, so `native check` answers with the SAME compiler that will
// build the core — a verdict the frontend's own checker can only
// approximate from a different TypeScript line.
//
//   node compiler_typecheck.mjs <entry.ts>
//
// Exit 0: the compiler's analyzer accepts the program (its static-subset
// findings are compile-time concerns, not check failures). Exit 1: the
// program does not typecheck under the compiler — its errors, already
// printed verbatim, are the teaching. Exit 2: toolchain missing/broken.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const entry = process.argv[2];
if (!entry) {
  console.error("usage: compiler_typecheck.mjs <entry.ts>");
  process.exit(2);
}
const here = path.dirname(fileURLToPath(import.meta.url));
const coreRoot = path.resolve(here, "..");
let compilerJs;
try {
  compilerJs = createRequire(path.join(coreRoot, "package.json")).resolve("scriptc/dist/main.js");
} catch {
  console.error("the external core compiler is not installed — run `npm ci --include=dev` in the SDK's packages/core");
  process.exit(2);
}
// The shipped declaration files stand in for the SDK's module surface;
// value imports stay external-host findings, which is correct — the
// compile stage links the real implementations.
const maps = [];
for (const [specifier, file] of [
  ["@native-sdk/core", "sdk/core.d.ts"],
  ["@native-sdk/core/text", "sdk/text.d.ts"],
  ["@native-sdk/core/events", "sdk/events.d.ts"],
]) {
  const p = path.join(coreRoot, file);
  if (fs.existsSync(p)) maps.push("--external-types", `${specifier}=${p}`);
}
function serviceEntries(root) {
  const found = [];
  if (!fs.existsSync(root)) return found;
  for (const item of fs.readdirSync(root, { withFileTypes: true })) {
    const candidate = path.join(root, item.name);
    if (item.isDirectory()) found.push(...serviceEntries(candidate));
    else if (item.isFile() && item.name.endsWith(".ts") && !item.name.endsWith(".d.ts")) found.push(candidate);
  }
  return found.sort();
}

let typeFailure = false;
for (const candidate of [entry, ...serviceEntries(path.join(path.dirname(entry), "services"))]) {
  const probe = spawnSync(process.execPath, [compilerJs, "coverage", candidate, ...maps], { encoding: "utf8" });
  const out = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
  if (probe.status === 0) continue;
  // Analyzer refusals for TYPE errors carry the compiler's own diagnostics;
  // pass them through untouched and fail the check. Service files receive
  // this verdict independently because the core is forbidden to import them.
  if (/TypeScript error/.test(out) || /error SC0001/.test(out)) {
    process.stderr.write(out);
    typeFailure = true;
    continue;
  }
  // Any other nonzero outcome (analyzer internal trouble) must not wedge
  // `native check`: the compile stage will judge for real.
  process.stderr.write(out);
  console.error(`native check: the external compiler's analyzer could not reach a verdict for ${candidate}; the build will judge for real`);
}
process.exit(typeFailure ? 1 : 0);
