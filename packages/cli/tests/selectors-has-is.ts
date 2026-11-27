// `:is()` with a complex argument inside `:has()`. The leading combinator relates the compound's
// own subject to the anchored element, while the argument's chain is a constraint above it, so
// `:has(> :is(.parent > .child))` wants a child that matches `.child` with `.parent` above it.
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
<html><head><title>has-is</title><style>
#s1:has(> :is(.parent > .child)) { color: rgb(0, 128, 0); }
#s2:has(> :is(.parent .descendant)) { color: rgb(0, 0, 255); }
#s3:has(:is(.deep-parent > .deep-child)) { color: rgb(255, 0, 0); }
</style></head><body>
<div id="s1"><div id="c1"></div></div>
<div id="s2"><div id="c2"></div></div>
<div id="s3"><div id="p3"><div id="c3"></div></div></div>
<script>
function color(id: string): string {
  return getComputedStyle(document.getElementById(id)!).color;
}
function all(): string {
  return color("s1") + " " + color("s2") + " " + color("s3");
}
console.log("hasis initial=" + all());
document.getElementById("s1")!.classList.add("parent");
document.getElementById("s2")!.classList.add("parent");
document.getElementById("c3")!.classList.add("deep-child");
void document.documentElement.offsetTop;
console.log("hasis half=" + all());
document.getElementById("c1")!.classList.add("child");
document.getElementById("c2")!.classList.add("descendant");
document.getElementById("p3")!.classList.add("deep-parent");
void document.documentElement.offsetTop;
console.log("hasis full=" + all());
document.getElementById("c1")!.classList.remove("child");
void document.documentElement.offsetTop;
console.log("hasis undone=" + all());
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-has-is-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
for (const value of [":has(> :is(.parent > .child))", ":has(> :is(.parent .descendant))", ":has(:is(.deep-parent > .deep-child))"]) {
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

// Chrome's values for the same page. The middle line has `.parent` but not yet the matching
// descendant, so nothing matches; the full line has all three.
const BLACK = "rgb(0, 0, 0)";
const want: [string, string][] = [
  ["hasis initial", `${BLACK} ${BLACK} ${BLACK}`],
  ["hasis half", `${BLACK} ${BLACK} ${BLACK}`],
  ["hasis full", "rgb(0, 128, 0) rgb(0, 0, 255) rgb(255, 0, 0)"],
  ["hasis undone", `${BLACK} rgb(0, 0, 255) rgb(255, 0, 0)`],
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
