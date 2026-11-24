// Invalidation of the selector forms the engine matches at runtime: a filtered :nth-child()
// count, a filter on an ancestor compound, a filter inside :not(), a :has() argument that walks
// past the next sibling, and a state change inside a subject's :has().
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><title>invalidation</title><style>
#l1 p:nth-last-child(even of .x) { color: rgb(0, 128, 0); }
#l2 p:nth-child(odd of .y) span { color: rgb(0, 128, 0); }
#l3.ancestor p:not(:nth-child(even of .z)) { color: rgb(0, 0, 255); }
#h1:has(+ .a + .b) { color: rgb(9, 9, 9); }
#h2:has(input:checked) { color: rgb(8, 8, 8); }
#e1:has(:empty) { color: rgb(7, 7, 7); }
#e2 div:empty { color: rgb(6, 6, 6); }
</style></head><body>
<div id="l1">
  <p>a</p><p class="x">b</p><p class="x">c</p><p class="x">d</p>
  <p class="x" id="t1">e</p><p class="x">f</p><p>g</p><p>h</p>
</div>
<div id="l2">
  <p>a <span id="s1">x</span></p><p class="y" id="t2">b <span id="s2">x</span></p>
  <p class="y">c <span id="s3">x</span></p><p class="y">d <span id="s4">x</span></p>
  <p class="y">e <span id="s5">x</span></p><p>f</p>
</div>
<div id="l3">
  <p id="q1">a</p><p class="z" id="q2">b</p><p class="z" id="q3">c</p>
  <p class="z" id="q4">d</p><p class="z" id="q5">e</p><p id="q6">f</p>
</div>
<div id="h1"></div><div class="a"></div><div class="b"></div>
<div id="h2"><input id="cb" type="checkbox"></div>
<div id="e1"><span id="ec"></span></div>
<div id="e2"><div id="ed"></div></div>
<script>
function color(id: string): string {
  return getComputedStyle(document.getElementById(id)!).color;
}
function marks(ids: string[]): string {
  const greens: string[] = [];
  for (const id of ids) {
    const c = getComputedStyle(document.getElementById(id)!).color;
    greens.push(c === "rgb(0, 128, 0)" ? "G" : c === "rgb(0, 0, 255)" ? "B" : "-");
  }
  return greens.join("");
}
function l1marks(): string {
  let out = "";
  for (const p of document.querySelectorAll("#l1 p")) {
    const c = getComputedStyle(p as Element).color;
    out += c === "rgb(0, 128, 0)" ? "G" : "-";
  }
  return out;
}
const l2ids = ["s1", "s2", "s3", "s4", "s5"];
const l3ids = ["q1", "q2", "q3", "q4", "q5", "q6"];
console.log("l1 initial=" + l1marks());
console.log("l2 initial=" + marks(l2ids));
console.log("l3 initial=" + marks(l3ids));
console.log("h1 static=" + getComputedStyle(document.getElementById("h1")!).color);
console.log("h2 checked=" + getComputedStyle(document.getElementById("h2")!).color);
console.log("empty initial=" + color("e1") + " " + color("ed"));
document.documentElement.offsetTop;
document.getElementById("t1")!.classList.toggle("x");
document.getElementById("t2")!.classList.toggle("y");
document.getElementById("l3")!.classList.toggle("ancestor");
document.getElementById("ec")!.appendChild(document.createTextNode("x"));
document.getElementById("ed")!.textContent = "y";
(document.getElementById("cb") as HTMLInputElement).checked = true;
void document.documentElement.offsetTop;
console.log("l1 changed=" + l1marks());
console.log("l2 changed=" + marks(l2ids));
console.log("l3 changed=" + marks(l3ids));
console.log("h2 after=" + getComputedStyle(document.getElementById("h2")!).color);
console.log("empty after=" + color("e1") + " " + color("ed"));
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-invalidation-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
for (const value of ["nth-last-child(even of .x)", "nth-child(odd of .y)", ":not(:nth-child(even of .z))", ":has(+ .a + .b)", ":has(input:checked)"]) {
  const line = log.split("\n").find((l) => l.includes(`'${value}'`));
  check(`the build accepts '${value}'`, line === undefined, line ?? "");
}

const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "snap.png") } });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = new Map<string, string>();
for (const line of run.stdout.split("\n")) {
  const m = /^(\w+) ([\w-]+)=(.*)$/.exec(line);
  if (m !== null) got.set(`${m[1]} ${m[2]}`, m[3]);
}

// Every expectation is what Chrome computes for the same page: before the change and after it.
const want: [string, string][] = [
  // .x siblings are the 5 inner ones; even from the end are the 2nd and 4th (p3, p5).
  ["l1 initial", "--G-G---"],
  // Removing .x from the 4th of them leaves 4 filtered, so the 2nd and 4th from the end move.
  ["l1 changed", "-G-G----"],
  // The 4 .y siblings are the middle ones; odd from the start are the 1st and 3rd of them.
  ["l2 initial", "-G-G-"],
  ["l2 changed", "--G-G"],
  ["l3 initial", "------"],
  ["l3 changed", "BB-B-B"],
  ["h1 static", "rgb(9, 9, 9)"],
  ["h2 checked", "rgb(0, 0, 0)"],
  ["h2 after", "rgb(8, 8, 8)"],
  // An :empty condition, and a :has(:empty) argument, follow the text a script writes.
  ["empty initial", "rgb(7, 7, 7) rgb(6, 6, 6)"],
  ["empty after", "rgb(0, 0, 0) rgb(0, 0, 0)"],
];
for (const [key, value] of want) {
  const have = got.get(key);
  check(`${key} is ${value}`, have === value, have === undefined ? "missing" : `got ${have}`);
}

if (failed > 0) {
  console.log(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
