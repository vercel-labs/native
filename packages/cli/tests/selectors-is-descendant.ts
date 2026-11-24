// A descendant combinator before an `:is()` argument whose own chain also walks up: both chains
// name ancestors of the subject and their order is open, so each arrangement has to match. This
// is the shape `:has(~ #sibling :is(.inner #target))` and `.outer :is(.inner .leaf)` take.
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
<html><head><title>is-descendant</title><style>
.outer :is(.inner .leaf) { color: rgb(0, 128, 0); }
#subject:has(~ #sib :is(.mid #target)) { color: rgb(0, 0, 255); }
</style></head><body>
<div class="outer"><div class="inner"><div class="leaf" id="l1">a</div></div></div>
<div class="inner"><div class="outer"><div class="leaf" id="l2">b</div></div></div>
<div class="outer"><div class="inner"><div><div class="leaf" id="l3">c</div></div></div></div>
<div id="subject"></div>
<div id="sib"><div id="midbox"><div id="target"></div></div></div>
<script>
function color(id: string): string {
  return getComputedStyle(document.getElementById(id)!).color;
}
console.log("isdesc leaves=" + color("l1") + " " + color("l2") + " " + color("l3"));
console.log("isdesc has=" + color("subject"));
document.getElementById("midbox")!.classList.add("mid");
void document.documentElement.offsetTop;
console.log("isdesc has-mid=" + color("subject"));
document.getElementById("midbox")!.classList.remove("mid");
void document.documentElement.offsetTop;
console.log("isdesc has-undone=" + color("subject"));
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-isdesc-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
for (const value of [".outer :is(.inner .leaf)", ":has(~ #sib :is(.mid #target))"]) {
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

const GREEN = "rgb(0, 128, 0)";
const BLUE = "rgb(0, 0, 255)";
const BLACK = "rgb(0, 0, 0)";
// Chrome matches both orders of the two ancestors (`l1` has `.outer` above `.inner`, `l2` the
// other way round) and a deeper gap (`l3`); the :has() rule follows the class changing.
const want: [string, string][] = [
  ["isdesc leaves", `${GREEN} ${GREEN} ${GREEN}`],
  ["isdesc has", BLACK],
  ["isdesc has-mid", BLUE],
  ["isdesc has-undone", BLACK],
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
