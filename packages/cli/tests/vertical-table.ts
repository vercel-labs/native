// A vertical table's grid runs in the table's own frame: rows stack along the page's block axis
// and the cells of a row run down the page's inline axis. A horizontal table with the same markup
// stacks its rows down the page, so comparing the two shows which axis the grid took.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=300"><style>
body { margin: 0; font: 16px monospace; }
table { border-spacing: 0; margin: 10px; }
td { width: 40px; height: 40px; border: 2px solid #000; padding: 0; }
#v { writing-mode: vertical-lr; }
</style></head><body>
<table id="h"><tr id="h1"><td id="h11"></td><td id="h12"></td></tr><tr><td id="h21"></td><td id="h22"></td></tr></table>
<table id="v"><tr id="v1"><td id="v11"></td><td id="v12"></td></tr><tr><td id="v21"></td><td id="v22"></td></tr></table>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function rect(id: string): string {
  const r = document.getElementById(id)!.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height].map((n) => Math.round(n)).join(",");
}
console.log("OUT " + [
  "h11=" + rect("h11"), "h12=" + rect("h12"), "h21=" + rect("h21"), "h22=" + rect("h22"),
  "v11=" + rect("v11"), "v12=" + rect("v12"), "v21=" + rect("v21"), "v22=" + rect("v22"),
].join(" "));
`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-table-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);

const line = (run.stdout + run.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
console.log(`     ${got}`);
const field = (name: string): string => {
  const at = got.indexOf(name + "=");
  if (at < 0) return "";
  const rest = got.slice(at + name.length + 1);
  const end = rest.indexOf(" ");
  return end < 0 ? rest : rest.slice(0, end);
};

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const CELL = 44;   // 40px of content and a 2px border on both sides
const X = 10;      // the table's margin
const at = (id: string): number[] => field(id).split(",").map((n) => Number(n));
const same = (a: number[], x: number, y: number): boolean =>
  a[0] === x && a[1] === y && a[2] === CELL && a[3] === CELL;
const h11 = at("h11");
check("a horizontal table stacks its rows down the page",
  same(h11, X, X) && same(at("h12"), X + CELL, X) && same(at("h21"), X, X + CELL), field("h21"));
const v11 = at("v11");
check("a vertical table runs its first row's cells down the page",
  same(at("v12"), v11[0], v11[1] + CELL), field("v12"));
check("its second row is the next column across the page",
  same(at("v21"), v11[0] + CELL, v11[1]) && same(at("v22"), v11[0] + CELL, v11[1] + CELL), field("v22"));
check("every cell is one 44px square",
  ["v11", "v12", "v21", "v22", "h11", "h12", "h21", "h22"].every((id) => at(id)[2] === CELL && at(id)[3] === CELL),
  field("v11"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
