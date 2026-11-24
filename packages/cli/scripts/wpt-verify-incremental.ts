// Runs the WPT directories incremental layout must agree with under NATIVE_VERIFY_INCREMENTAL=1,
// which lays every frame out a second time from scratch, and fails when any page's reused layout
// differs from it. Pass/fail of the pages themselves is the regular `wpt run`'s concern; this
// checks only that incremental layout gets the same boxes.
//   node scripts/wpt-verify-incremental.ts [--jobs n] [dir...]
//   pnpm --filter @native-sdk/cli wpt:verify-incremental
// The WPT checkout comes from `native wpt fetch` (or $NATIVE_WPT). The whole list is several
// thousand pages, an hour or more; pass directories to check fewer.

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** The directories whose pages exercise layout reuse: positioned boxes, scroll extents,
 *  display types, tables, flex, grid, and block flow. */
export const VERIFY_DIRS = [
  "css/css-position",
  "css/cssom-view",
  "css/css-display",
  "css/css-tables",
  "css/css-flexbox",
  "css/css-grid",
  "css/CSS2/normal-flow",
];

const args = process.argv.slice(2);
let jobs = "1";
const dirs: string[] = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--jobs") jobs = args[++i];
  else dirs.push(args[i]);
}

const log = mkdtempSync(join(tmpdir(), "native-verify-incremental-"));
const out = join(log, "results.json");
const r = spawnSync(process.execPath, ["compiler/cli.ts", "wpt", "run", ...(dirs.length > 0 ? dirs : VERIFY_DIRS),
  "--jobs", jobs, "--out", out], {
  cwd: ROOT,
  stdio: ["ignore", "inherit", "inherit"],
  env: { ...process.env, NATIVE_VERIFY_INCREMENTAL: "1", NATIVE_VERIFY_LOG: log },
});

const lines: string[] = [];
for (const f of readdirSync(log)) {
  if (!f.startsWith("verify-")) continue;
  for (const l of readFileSync(join(log, f), "utf8").split("\n")) if (l !== "") lines.push(l);
}
let pages = 0;
let errors = 0;
const haveResults = existsSync(out);
if (haveResults) {
  for (const res of JSON.parse(readFileSync(out, "utf8")).results as { status: string }[]) {
    if (res.status === "skip") continue;
    pages++;
    if (res.status === "error") errors++;
  }
}
rmSync(log, { recursive: true, force: true });

if (r.status !== 0 || !haveResults) {
  console.error(`native: wpt run exited ${r.status ?? r.signal}`);
  process.exit(2);
}
// Pages that didn't build or crashed were never laid out, so their verdict says nothing: a run
// where most of them did is a broken run, not a clean one.
if (pages === 0 || errors > pages / 2) {
  console.error(`native: ${errors} of ${pages} pages errored; the verify run checked too little to count`);
  process.exit(2);
}
if (lines.length > 0) {
  console.error(`\n${lines.length} incremental layout mismatch line(s) over ${pages} pages:`);
  for (const l of lines.slice(0, 200)) console.error(`  ${l.replace("\t", " — ")}`);
  process.exit(1);
}
console.log(`\nincremental layout matched a full layout on all ${pages} pages (${errors} errored)`);
