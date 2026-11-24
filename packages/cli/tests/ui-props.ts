// caret-color, resize and interactivity: the caret takes its own colour, a textarea shows its
// resize grip and the grip drags the box to a new size, and an inert box takes no focus.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=200"><style>
body { margin: 0; font: 16px monospace; }
#f { position: absolute; left: 10px; top: 10px; caret-color: rgb(255, 0, 0); }
#g { position: absolute; left: 10px; top: 40px; caret-color: rgb(0, 0, 255); caret-shape: block; }
#ta { position: absolute; left: 10px; top: 60px; width: 160px; height: 80px; }
#inert { position: absolute; left: 250px; top: 10px; interactivity: inert; }
</style></head><body>
<input id="f" value="ab">
<input id="g" value="xyz">
<textarea id="ta"></textarea>
<div id="inert"><button id="b">x</button></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const f = document.getElementById("f") as HTMLElement;
const ta = document.getElementById("ta") as HTMLElement;
log("caret " + getComputedStyle(f).caretColor);
const plain = document.createElement("div");
document.body.appendChild(plain);
log("auto " + getComputedStyle(plain).caretColor);
document.body.style.caretColor = "rgb(0, 0, 255)";
log("inherit " + getComputedStyle(plain).caretColor);
log("resize " + getComputedStyle(ta).resize);
log("default " + getComputedStyle(plain).resize);
const inertBox = document.getElementById("inert") as HTMLElement;
log("interactivity " + getComputedStyle(inertBox).interactivity);
const g = document.getElementById("g") as HTMLElement;
log("shape auto " + getComputedStyle(f).caretShape);
g.style.caretShape = "underscore";
log("underscore " + getComputedStyle(g).caretShape);
g.style.caretShape = "block";
log("block " + getComputedStyle(g).caretShape);
const b = document.getElementById("b") as HTMLElement;
b.focus();
log("inert focus " + String(document.activeElement === b));
const ok = document.createElement("button");
document.body.appendChild(ok);
ok.focus();
log("plain focus " + String(document.activeElement === ok));
document.addEventListener("mouseup", function () {
  const r = ta.getBoundingClientRect();
  log("size " + Math.round(r.width) + " " + Math.round(r.height));
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-ui-props-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const png = join(dir, "out.png");
// The press lands in the textarea's grip — its bottom-right corner — and drags out 40 by 30.
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "dragat 160 130 200 160 | click #f | frame 2" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const lines = r.stdout.split("\n").slice(0, -1);
for (const line of lines) console.log(`     got ${JSON.stringify(line)}`);
const at = (i: number): string => lines[i] ?? "";
check("caret-color computes to its colour", at(0) === "caret rgb(255, 0, 0)", at(0));
check("and defaults to auto", at(1) === "auto auto", at(1));
check("caret-color inherits", at(2) === "inherit rgb(0, 0, 255)", at(2));
check("a textarea resizes both ways", at(3) === "resize both", at(3));
check("a plain box doesn't resize", at(4) === "default none", at(4));
check("interactivity computes inert", at(5) === "interactivity inert", at(5));
check("caret-shape defaults to auto", at(6) === "shape auto auto", at(6));
check("caret-shape parses underscore", at(7) === "underscore underscore", at(7));
check("caret-shape parses block", at(8) === "block block", at(8));
check("an inert button takes no focus", at(9) === "inert focus false", at(9));
check("a plain button takes focus", at(10) === "plain focus true", at(10));
// The drag pressed at the grip and moved 40 across and 30 down, so the box grew by that much.
const size = /^size (\d+) (\d+)$/.exec(at(11));
check("the grip drag sized the box", size !== null && size[1] === "200" && size[2] === "110", at(11));

// The caret in the input is drawn in the rule's red, not the text's black.
const img = decodePng(png);
let red = 0;
for (let i = 0; i < img.rgba.length; i += 4) {
  if (img.rgba[i] > 180 && img.rgba[i + 1] < 80 && img.rgba[i + 2] < 80) red++;
}
check("the caret paints in caret-color", red >= 20, `${red} red pixels`);

// The block caret covers the character it sits on, so it paints a wide blue rect, not a 1.5px bar.
const blockPng = join(dir, "block.png");
const rb = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: blockPng, NATIVE_STEPS: "click #g | frame 2" },
});
if (rb.status !== 0) throw new Error(`render failed\n${rb.stderr}`);
const blockImg = decodePng(blockPng);
let blue = 0, blueCols = new Set<number>();
for (let y = 0; y < blockImg.h; y++) for (let x = 0; x < blockImg.w; x++) {
  const o = (y * blockImg.w + x) * 4;
  if (blockImg.rgba[o + 2] > 180 && blockImg.rgba[o] < 80 && blockImg.rgba[o + 1] < 80) {
    blue++;
    blueCols.add(x);
  }
}
check("a block caret is a wide filled rect", blue >= 150 && blueCols.size >= 8,
  `${blue} blue pixels over ${blueCols.size} columns`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
