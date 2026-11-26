// The `all` property: a CSS-wide keyword applied to every property at the declaration's place in
// the cascade, and a logical side inheriting the parent's value from the physical side it names.
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
<html><head><title>all</title><style>
#initial { color: rgb(255, 0, 0); padding: 10px; all: initial; }
#unset { color: rgb(255, 0, 0); padding: 10px; all: unset; }
#inherit { padding: 10px; all: inherit; }
#logical { padding-top: inherit; padding-block-start: inherit; }
#after { color: rgb(1, 2, 3); all: initial; color: rgb(4, 5, 6); }
/* The initial value of display is inline, for display: initial and for all: initial. */
#disp { display: initial; }
#disp2 { all: initial; }
#disp3 { display: initial; }
</style></head><body>
<div style="color: rgb(0, 0, 255); padding: 7px">
  <div id="initial">a</div><div id="unset">b</div><div id="inherit">c</div>
  <div id="logical">d</div><div id="after">e</div>
  <span id="disp">f</span><span id="disp2">g</span><div id="disp3">h</div>
</div>
<script>
function style(id: string): CSSStyleDeclaration {
  return getComputedStyle(document.getElementById(id)!);
}
for (const id of ["initial", "unset", "inherit", "logical", "after"]) {
  console.log(id + " color=" + style(id).color);
  console.log(id + " pad=" + style(id).paddingTop);
}
console.log("disp value=" + style("disp").display + " " + style("disp2").display + " " + style("disp3").display);
console.log("supports value=" + (CSS.supports("all: unset") ? "yes" : "no"));
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-all-"));
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

// Chrome's values for the same page. `all: initial` takes every property to its initial value,
// `all: unset` inherits what inherits (the colour) and resets what does not (the padding), and
// `all: inherit` takes the parent's padding too. A declaration after `all` still wins.
const BLACK = "rgb(0, 0, 0)";
const BLUE = "rgb(0, 0, 255)";
const want: [string, string][] = [
  ["initial color", BLACK],
  ["initial pad", "0"],
  ["unset color", BLUE],
  ["unset pad", "0"],
  ["inherit color", BLUE],
  ["inherit pad", "7px"],
  ["logical color", BLUE],
  ["logical pad", "7px"],
  ["after color", "rgb(4, 5, 6)"],
  ["after pad", "0"],
  // A div is block through the UA sheet; `display: initial` asks for the CSS initial, inline.
  ["disp value", "inline inline inline"],
  ["supports value", "yes"],
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
