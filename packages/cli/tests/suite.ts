// Runs every test file in tests/, one after another, and fails if any of them fails:
//   npm test                      (typechecks first, in a scratch TMPDIR)
//   node tests/suite.ts dom calc  (just those files)
// A new test only has to be a tests/*.ts file that exits non-zero when it fails; there is no list
// to add it to. Files that aren't tests of their own are named in NOT_TESTS.

import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = dirname(fileURLToPath(import.meta.url));

/** Helpers, tools and local-only checks that live in tests/ but aren't part of the suite. */
const NOT_TESTS = new Set([
  "suite.ts",
  "scratch.ts", // the TMPDIR wrapper npm test runs this file in
  "png.ts", // the PNG reader the pixel tests import
  "wpt-regressions.ts", // compares WPT results with a git revision; run by hand or by a gate
  "lorenz.ts", // needs a fixture outside the repository
]);

const wanted = process.argv.slice(2).map((name) => (name.endsWith(".ts") ? name : `${name}.ts`));
const files = readdirSync(DIR)
  .filter((f) => f.endsWith(".ts") && !NOT_TESTS.has(f))
  .filter((f) => wanted.length === 0 || wanted.includes(f))
  .sort();
if (wanted.length > 0 && files.length !== wanted.length) {
  const missing = wanted.filter((w) => !files.includes(w));
  console.error(`no such test: ${missing.join(", ")}`);
  process.exit(2);
}

const failed: string[] = [];
const started = performance.now();
for (const file of files) {
  console.log(`\n# ${file}`);
  const t = performance.now();
  const r = spawnSync(process.execPath, [join(DIR, file)], { stdio: "inherit" });
  const secs = ((performance.now() - t) / 1000).toFixed(1);
  if (r.status !== 0) {
    failed.push(file);
    console.log(`# ${file} FAILED (exit ${r.status ?? r.signal}, ${secs}s)`);
  } else {
    console.log(`# ${file} ok (${secs}s)`);
  }
}

const total = ((performance.now() - started) / 1000).toFixed(0);
if (failed.length > 0) {
  console.error(`\n${failed.length} of ${files.length} test files failed (${total}s): ${failed.join(", ")}`);
  process.exit(1);
}
console.log(`\nall ${files.length} test files passed (${total}s)`);
