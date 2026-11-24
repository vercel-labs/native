// A logical property's computed value is the physical side's it names (CSS Logical 1 §4): a read
// answers from that side, whichever of the two declarations the cascade gave the side.
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
<html><head><meta name="native-window" content="width=200, height=100"><style>
#a { width: 50px; inline-size: 60px; }
#b { inline-size: 70px; width: 40px; }
#c { margin-block-start: 5px; }
#d { border-block-end: 3px dashed rgb(1, 2, 3); }
#e { writing-mode: vertical-rl; border-inline-start: 4px solid rgb(4, 5, 6); }
#f { direction: rtl; padding-inline-start: 7px; }
#h { border-block: 2px solid rgb(9, 8, 7); }
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div>
<div id="e"></div><div id="f"></div><div id="h"></div><button id="g">button</button>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const cs = (id: string) => getComputedStyle(document.getElementById(id)!);
const a = cs("a");
const b = cs("b");
const c = cs("c");
const d = cs("d");
const e = cs("e");
const f = cs("f");
const g = cs("g");
const h = cs("h");
console.log("OUT "
  + "|a.inline=" + a.inlineSize + "|a.width=" + a.width
  + "|b.inline=" + b.inlineSize + "|b.width=" + b.width
  + "|c.marginBlockStart=" + c.marginBlockStart + "|c.marginTop=" + c.marginTop
  + "|d.endColor=" + d.borderBlockEndColor + "|d.bottomColor=" + d.borderBottomColor
  + "|d.endWidth=" + d.borderBlockEndWidth + "|d.endStyle=" + d.borderBlockEndStyle
  + "|e.inlineStart=" + e.borderInlineStartWidth + "|e.top=" + e.borderTopWidth
  + "|f.padInlineStart=" + f.paddingInlineStart + "|f.padRight=" + f.paddingRight
  + "|g.endColor=" + g.borderBlockEndColor + "|g.bottomColor=" + g.borderBottomColor
  + "|d.block=" + d.getPropertyValue("border-block")
  + "|h.block=" + h.getPropertyValue("border-block"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-logical-computed-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
const field = (name: string): string => {
  const at = got.indexOf("|" + name + "=");
  if (at < 0) return "";
  const start = at + name.length + 2;
  const end = got.indexOf("|", start);
  return got.slice(start, end < 0 ? got.length : end);
};
// The later declaration wins, and both names report it.
check("inline-size later than width wins", field("a.inline") === "60px" && field("a.width") === "60px", got);
check("width later than inline-size wins", field("b.inline") === "40px" && field("b.width") === "40px", got);
check("margin-block-start reports the top margin", field("c.marginBlockStart") === "5px" && field("c.marginTop") === "5px", got);
check("border-block-end reports the bottom side", field("d.endColor") === "rgb(1, 2, 3)" && field("d.bottomColor") === "rgb(1, 2, 3)", got);
check("its width and style come from the shorthand", field("d.endWidth") === "3px" && field("d.endStyle") === "dashed", got);
check("a vertical page's inline-start is its top edge", field("e.inlineStart") === "4px" && field("e.top") === "4px", got);
check("an rtl box's inline-start is its right edge", field("f.padInlineStart") === "7px" && field("f.padRight") === "7px", got);
check("an undeclared logical side reads the UA's physical border",
  field("g.endColor") === "rgb(118, 118, 118)" && field("g.endColor") === field("g.bottomColor"), got);
check("a logical shorthand with different sides writes both",
  field("d.block").endsWith("3px dashed rgb(1, 2, 3)") && !field("d.block").includes("NaN"), got);
check("a logical shorthand whose sides agree writes it once", field("h.block") === "2px solid rgb(9, 8, 7)", got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
