// Cascade layers a script declares: style sheets added at runtime put their rules in the layers
// their @layer blocks name, ordered by declaration like a compiled sheet's.
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
<html><head><title>layers</title></head><body>
<div id="anon">a</div><div id="named">b</div><div id="imp">c</div>
<div id="nested">d</div>
<script>
function add(css: string): void {
  const s = document.createElement("style");
  s.textContent = css;
  document.head.appendChild(s);
}
// Two anonymous layers: the later one wins for normal declarations.
add("@layer { #anon { color: rgb(255, 0, 0); } }");
add("@layer { #anon { color: rgb(0, 128, 0); } }");
// Named layers in the order @layer a, b; declares: b is later, so b wins.
add("@layer a, b;");
add("@layer b { #named { color: rgb(0, 0, 255); } }");
add("@layer a { #named { color: rgb(255, 0, 0); } }");
// Important declarations reverse the layer order: the earlier layer wins.
add("@layer a { #imp { color: rgb(255, 0, 0) !important; } }");
add("@layer b { #imp { color: rgb(0, 0, 255) !important; } }");
// A nested layer's rules come before its parent's own rules.
add("@layer outer { @layer inner { #nested { color: rgb(255, 0, 0); } } #nested { color: rgb(0, 0, 255); } }");
const color = (id: string): string => getComputedStyle(document.getElementById(id)!).color;
console.log("anon value=" + color("anon"));
console.log("named value=" + color("named"));
console.log("imp value=" + color("imp"));
console.log("nested value=" + color("nested"));
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-layers-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "snap.png") } });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = new Map<string, string>();
for (const line of run.stdout.split("\n")) {
  const m = /^(\w+) ([\w-]+)=(.*)$/.exec(line);
  if (m !== null) got.set(`${m[1]} ${m[2]}`, m[3]);
}

const RED = "rgb(255, 0, 0)";
const GREEN = "rgb(0, 128, 0)";
const BLUE = "rgb(0, 0, 255)";
// Chrome's values for the same page.
const want: [string, string][] = [
  ["anon value", GREEN],
  ["named value", BLUE],
  ["imp value", RED],
  ["nested value", BLUE],
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
