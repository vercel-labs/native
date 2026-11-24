// The CSS-wide keywords: inherit copies the parent's value, initial takes the property's initial
// one, unset/revert inherit on an inherited property and take the initial value otherwise, and
// each works on shorthands and with !important like any other value.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; background: #ffffff; }
.kid { width: 20px; height: 20px; border: 6px solid currentColor; }

#p1 { position: absolute; top: 0; left: 0; color: #00ff00; }
#a { color: inherit; }
#p2 { position: absolute; top: 0; left: 50px; color: #00ffff; }
#b { color: unset; }
#p3 { position: absolute; top: 0; left: 100px; color: #ff00ff; }
#c { color: revert; }

#p4 { position: absolute; top: 40px; left: 0; padding-left: 20px; }
#d { width: 20px; height: 20px; background: #0000ff; padding-left: 20px; padding-left: unset; }

#p5 { position: absolute; top: 80px; left: 0; width: 40px; height: 20px; border: 6px solid #ff8800; }
#e { width: 20px; height: 20px; background: #000000; border: inherit; }

#f { position: absolute; top: 130px; left: 0; width: 20px; height: 20px; background-color: #ff0000; background-color: initial; }

#p7 { position: absolute; top: 160px; left: 0; color: #0000ff; }
#g { color: #ff0000; }
#g.wide { color: inherit !important; }
#p8 { position: absolute; top: 160px; left: 50px; color: #00ff00; }
#i { border: 6px solid currentColor; width: 20px; height: 20px; color: initial; }
#h { position: absolute; top: 130px; left: 50px; font: inherit; }
</style></head><body>
<div id="p1"><div class="kid" id="a"></div></div>
<div id="p2"><div class="kid" id="b"></div></div>
<div id="p3"><div class="kid" id="c"></div></div>
<div id="p4"><div id="d"></div></div>
<div id="p5"><div id="e"></div></div>
<div id="f"></div>
<div id="p7"><div class="kid wide" id="g"></div></div>
<div id="p8"><div id="i">x</div></div>
<div id="h"></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-wide-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
for (const prop of ["color: inherit", "color: unset", "color: revert", "padding-left: unset", "border: inherit",
  "background-color: initial", "font: inherit"]) {
  const line = log.split("\n").find((l) => l.includes(prop));
  check(`the build accepts '${prop}'`, line === undefined, line ?? "");
}

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const S = img.w / 200;
const at = (x: number, y: number): string => {
  const o = (Math.round(y * S) * img.w + Math.round(x * S)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const WHITE = "255,255,255";

check("color: inherit takes the parent's color", at(3, 3) === "0,255,0", `got ${at(3, 3)}`);
check("color: unset inherits, the property being inherited", at(53, 3) === "0,255,255", `got ${at(53, 3)}`);
check("color: revert falls back to the inherited value", at(103, 3) === "255,0,255", `got ${at(103, 3)}`);
// The child sits in a parent with 20px of left padding and has 20px of its own padding removed
// by `unset`: it is 20px wide, so nothing is painted past x=40.
check("padding-left: unset takes the initial value, not the parent's", at(45, 50) === WHITE, `got ${at(45, 50)}`);
check("and the box itself is still painted", at(25, 50) === "0,0,255", `got ${at(25, 50)}`);
check("border: inherit copies the parent's border", at(8, 88) === "255,136,0", `got ${at(8, 88)}`);
check("the child's content stays inside that border", at(20, 100) === "0,0,0", `got ${at(20, 100)}`);
check("background-color: initial paints nothing", at(10, 140) === WHITE, `got ${at(10, 140)}`);
check("an important inherit beats a more specific normal color", at(3, 163) === "0,0,255", `got ${at(3, 163)}`);
check("color: initial is black", at(53, 163) === "0,0,0", `got ${at(53, 163)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
