// Lists WPT tests that passed at a base revision but don't pass in a results file.
//   node tests/wpt-regressions.ts [base-rev] [results.json] [--layout]
// --layout compares only layout tests, which is what a headless host can run.
// Exits 1 if any previously passing test no longer passes.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const args = process.argv.slice(2).filter((a) => a !== "--layout");
// A host that can't paint skips the pixel reftests, so a gate over its results must skip them too.
const layoutOnly = process.argv.includes("--layout");
const base = args[0] ?? "HEAD";
const file = args[1] ?? "wpt/results.json";
const keep = (r: { kind: string }) => !layoutOnly || r.kind === "layout";
const old = JSON.parse(execFileSync("git", ["show", `${base}:./wpt/results.json`], { maxBuffer: 1 << 28 }).toString());
const now = JSON.parse(readFileSync(file, "utf8"));
const nowResults = now.results.filter(keep);
const status = new Map<string, string>(nowResults.map((r: { path: string; status: string }) => [r.path, r.status]));
const passed: string[] = old.results.filter(keep).filter((r: { status: string }) => r.status === "pass").map((r: { path: string }) => r.path);
// A test the run didn't include (another set of directories was measured) isn't a regression.
const lost = passed.filter((p) => status.has(p) && status.get(p) !== "pass");
const notRun = passed.filter((p) => !status.has(p)).length;
const gained = nowResults.filter((r: { status: string }) => r.status === "pass").length - (passed.length - lost.length);
console.log(`base ${base}: ${passed.length} passing; now lost ${lost.length}, gained ${gained}` +
  (notRun > 0 ? `, ${notRun} not in this run` : ""));
for (const p of lost) console.log(`  lost: ${p} (${status.get(p) ?? "missing"})`);
process.exit(lost.length > 0 ? 1 : 0);
