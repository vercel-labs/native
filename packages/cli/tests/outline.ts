// Outlines: outline-style/width/color/offset and the shorthand. An outline is painted outside
// the border box, moved out by its offset, and takes no room in layout.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = w * bpp + 1;
  const out = new Uint8Array(w * h * bpp);
  let prev = new Uint8Array(w * bpp);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * stride];
    const line = raw.subarray(y * stride + 1, y * stride + 1 + w * bpp);
    const cur = new Uint8Array(w * bpp);
    for (let x = 0; x < w * bpp; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const up = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      cur[x] = v & 255;
    }
    out.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba: out };
}

// Four boxes at known places, each 60x30 with a 2px gray border and a white background, so the
// pixels can tell the border box, the outline and its offset apart.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=420"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
.box { position: absolute; left: 40px; width: 60px; height: 30px; background: #ffffff; border: 2px solid #cccccc; }
#plain { top: 20px; outline: 2px solid #ff0000; }
#offset { top: 80px; outline: 3px solid #ff0000; outline-offset: 6px; }
#off { top: 140px; outline-width: 5px; outline-color: #ff0000; }
#cur { top: 190px; height: 20px; color: #0000ff; outline: 2px solid currentColor; }
#dash { top: 230px; outline: 2px dashed #ff0000; }
#dot { top: 275px; outline: 4px dotted #ff0000; }
#dbl { top: 330px; outline: 6px double #ff0000; }
#auto { top: 380px; outline: 2px auto #ff0000; }
</style></head><body>
<div class="box" id="plain"></div>
<div class="box" id="offset"></div>
<div class="box" id="off"></div>
<div class="box" id="cur"></div>
<div class="box" id="dash"></div>
<div class="box" id="dot"></div>
<div class="box" id="dbl"></div>
<div class="box" id="auto"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const plain = document.getElementById("plain")!;
console.log("plain outline=" + getComputedStyle(plain).outline);
console.log("plain width=" + getComputedStyle(plain).outlineWidth + " offset=" + getComputedStyle(plain).outlineOffset + " color=" + getComputedStyle(plain).outlineColor);
console.log("plain box=" + getComputedStyle(plain).width + "x" + getComputedStyle(plain).height);
console.log("an outline takes no room: left=" + getComputedStyle(plain).left + " width=" + getComputedStyle(plain).width);
const offset = document.getElementById("offset")!;
console.log("offset=" + getComputedStyle(offset).outlineOffset + " width=" + getComputedStyle(offset).outlineWidth);
const off = document.getElementById("off")!;
console.log("no style=" + getComputedStyle(off).outlineStyle);
off.style.outline = "1px solid #ff0000";
console.log("set inline=" + getComputedStyle(off).outline);
const cur = document.getElementById("cur")!;
console.log("currentColor=" + getComputedStyle(cur).outlineColor);
const dash = getComputedStyle(document.getElementById("dash")!);
console.log("dash=" + dash.outline + " style=" + dash.outlineStyle);
console.log("dot=" + getComputedStyle(document.getElementById("dot")!).outlineStyle);
const dbl = getComputedStyle(document.getElementById("dbl")!);
console.log("dbl=" + dbl.outlineStyle + " width=" + dbl.outlineWidth);
console.log("auto=" + getComputedStyle(document.getElementById("auto")!).outlineStyle);
`;

const EXPECTED_LOG: [string, string][] = [
  ["the shorthand reads back in CSS's order", "plain outline=rgb(255, 0, 0) solid 2px"],
  ["outline longhands are computed", "plain width=2px offset=0px color=rgb(255, 0, 0)"],
  ["an outline leaves the box's size alone", "plain box=60pxx30px"],
  ["an outline takes no room in layout", "an outline takes no room: left=40px width=60px"],
  ["outline-offset is computed", "offset=6px width=3px"],
  ["outline-width alone draws nothing", "no style=none"],
  ["an inline outline applies", "set inline=rgb(255, 0, 0) solid 1px"],
  ["currentColor resolves to the text color", "currentColor=rgb(0, 0, 255)"],
  ["a dashed outline computes to its style", "dash=rgb(255, 0, 0) dashed 2px style=dashed"],
  ["a dotted outline computes to its style", "dot=dotted"],
  ["a double outline computes to its style", "dbl=double width=6px"],
  ["an auto outline computes to auto", "auto=auto"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-outline-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();
// The snapshot is 2 device px per CSS px.
const at = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};

// #plain sits at (40, 20) with a 2px border: the outline's 2px ring is just outside it, so
// x = 36..38 is the outline's left edge and x = 40..42 the border.
check("the outline paints left of the border box", at(39, 35) === "255,0,0", `got ${at(39, 35)}`);
check("the outline sits above the border box", at(70, 19) === "255,0,0", `got ${at(70, 19)}`);
check("the border still paints inside it", at(41, 35) === "204,204,204", `got ${at(41, 35)}`);
check("the outline spans the box", at(105, 35) === "255,0,0", `got ${at(105, 35)}`);

// #offset moves the 3px ring out by 6px: its left edge is x = 31..34, and the gap between the
// ring and the border box stays white.
check("outline-offset moves the ring outwards", at(32, 95) === "255,0,0", `got ${at(32, 95)}`);
check("the offset leaves a gap", at(37, 95) === "255,255,255", `got ${at(37, 95)}`);

// #off had only a width and a color: no style, so nothing is drawn, even after the ring would
// be 5px wide. (The script then sets the shorthand inline, which draws a 1px ring.)
check("no outline without a style", at(36, 155) === "255,255,255" && at(40, 155) === "204,204,204",
  `got ${at(36, 155)} and ${at(40, 155)}`);

// currentColor follows the text color.
check("currentColor outlines use the text color", at(39, 200) === "0,0,255", `got ${at(39, 200)}`);

/** How many separate red runs a horizontal slice of the ring holds: dashes, dots or double lines. */
function redRuns(y: number, x0: number, x1: number): number {
  let runs = 0;
  let on = false;
  for (let x = x0; x <= x1; x++) {
    const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
    const red = img.rgba[o] > 170 && img.rgba[o + 1] < 90 && img.rgba[o + 2] < 90;
    if (red && !on) runs++;
    on = red;
  }
  return runs;
}

// #dash's 2px ring is dashes six pixels long with two between them, along its top edge.
const dashes = redRuns(229, 38, 106);
check("a dashed outline leaves gaps", dashes > 3, `${dashes} dashes`);
// #dot's 4px ring is round dots a width apart.
const dots = redRuns(273, 36, 108);
check("a dotted outline is dots with gaps", dots > 3, `${dots} dots`);
// #dbl's 6px ring is two 2px lines with a 2px gap between them, along its left edge.
const twoLines = redRuns(345, 34, 40);
check("a double outline is two rings", twoLines === 2, `${twoLines} lines`);
check("the gap between the double lines is empty", at(37, 345) !== "255,0,0", `got ${at(37, 345)}`);
// `auto` has no ring of its own here: it paints as a solid one.
check("an auto outline paints a solid ring", at(70, 379) === "255,0,0", `got ${at(70, 379)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
